-- Match Your Colors: unit tests of the decoders and helpers that need no game files: LZ4 blocks, half floats,
-- the game's map probing, the idle watch, numpy summation order, CIEDE2000 reference pairs, the color transfer,
-- the matcher's trim and accent rules and LUT building.
-- Usage: luajit tests/test_units.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_units.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Slim, Texture, Avatar = require('slim'), require('texture'), require('avatar')
local Colour, Matcher, Recolor = require('colour'), require('matcher'), require('recolor')
require('sheets').attach(Recolor)
local Transfer = require('transfer')
Matcher.use(Colour)
require('zones').attach(Matcher, Colour)
require('variety').attach(Matcher, Colour)
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local function from_hex(hex)
    return (hex:gsub('..', function(h) return string.char(tonumber(h, 16)) end))
end

check('LZ4 blocks decode to their data (python-lz4 vectors)', function()
    for i, case in ipairs(dofile(root .. '/tests/fixtures/lz4.lua')) do
        local packed, data = from_hex(case[1]), from_hex(case[2])
        local out = ffi.new('uint8_t[?]', #data + 1)
        local n = Slim.lz4(ffi.cast('const uint8_t *', packed), #packed, out, #data)
        assert(n == #data and ffi.string(out, n) == data, 'vector ' .. i)
    end
end)

check('malformed LZ4 blocks raise instead of writing out of bounds', function()
    local out = ffi.new('uint8_t[16]')
    for _, bad in ipairs({'\240', '\16', '\31\120\0', '\31\120\9\0', '\255\255'}) do
        local ok = pcall(Slim.lz4, ffi.cast('const uint8_t *', bad), #bad, out, 16)
        assert(not ok, 'accepted ' .. bad:gsub('.', function(c) return string.format('%02x', c:byte()) end))
    end
    local long = '\31\120\1\0' -- one literal, match of 15 + 4 bytes into a 16-byte buffer
    assert(not pcall(Slim.lz4, ffi.cast('const uint8_t *', long), #long, out, 16), 'match overrun accepted')
end)

check('LZ4: long overlapping matches (copied in whole periods) decode as byte by byte, at every offset and length '
      .. 'around the switch, up to a whole 256 KB chunk', function()
    -- One block: sequences of a few literals and a match, the expected output built byte by byte as the format says.
    local state = 12345
    local function random(n) -- deterministic (Park-Miller: exact in doubles), 0 .. n - 1
        state = (state * 16807) % 2147483647
        return state % n
    end
    local function length_bytes(rest) -- LZ4's 255-run extension of a length past 15
        local out = {}
        while rest >= 255 do out[#out + 1] = string.char(255) rest = rest - 255 end
        out[#out + 1] = string.char(rest)
        return table.concat(out)
    end
    local function block(matches)
        local total = 5
        for _, m in ipairs(matches) do total = total + m.literals + m.length end
        local packed, expected, n = {}, ffi.new('uint8_t[?]', total), 0
        for _, m in ipairs(matches) do
            local literals = {}
            for i = 1, m.literals do
                local byte = random(256)
                literals[i], expected[n] = string.char(byte), byte
                n = n + 1
            end
            local lit = table.concat(literals)
            local offset, length = math.min(m.offset, n), m.length
            local token = (#lit >= 15 and 15 or #lit) * 16 + (length - 4 >= 15 and 15 or length - 4)
            packed[#packed + 1] = string.char(token) .. (#lit >= 15 and length_bytes(#lit - 15) or '') .. lit
                .. string.char(offset % 256, math.floor(offset / 256)) .. (length - 4 >= 15 and length_bytes(length - 19) or '')
            for _ = 1, length do
                expected[n] = expected[n - offset]
                n = n + 1
            end
        end
        packed[#packed + 1] = string.char(0x50) .. 'tail!' -- the last sequence: literals only
        ffi.copy(expected + n, 'tail!', 5)
        return table.concat(packed), ffi.string(expected, n + 5)
    end
    -- The game's LuaJIT 2.1.0-alpha miscompiled this generator in some layouts of loaded modules (wrong bytes, an
    -- access violation; 2026-10-08): it runs interpreted. The decoder under test stays compiled.
    jit.off(block, true) -- lint-ok: R5 test generator only
    jit.off(random) -- lint-ok: R5 test generator only
    local cases = {}
    for _, offset in ipairs({1, 2, 3, 7, 64, 255, 256, 300}) do
        for _, length in ipairs({4, 255, 256, 257, 511, 4096, 20000}) do
            cases[#cases + 1] = {literals = 1 + random(300), offset = offset, length = length}
        end
    end
    for _ = 1, 200 do cases[#cases + 1] = {literals = random(40), offset = 1 + random(600), length = 4 + random(3000)} end
    local packed, expected = block(cases)
    local out = ffi.new('uint8_t[?]', #expected)
    assert(Slim.lz4(ffi.cast('const uint8_t *', packed), #packed, out, #expected) == #expected
           and ffi.string(out, #expected) == expected, 'mixed block')
    local chunk = 262144 -- one offset-1 match filling a chunk (its first byte a literal), as in the game's data
    packed, expected = block({{literals = 1, offset = 1, length = chunk - 6}})
    out = ffi.new('uint8_t[?]', chunk)
    assert(Slim.lz4(ffi.cast('const uint8_t *', packed), #packed, out, chunk) == chunk
           and ffi.string(out, chunk) == expected, 'a 256 KB run')
end)

check('a pattern mask is summed in blocks of whole rows with a pause after each, to the whole mip\'s sum exactly',
      function()
    -- the coverage before v1.4: the whole mip read and summed in one piece
    local function whole(pixels, info, layer, mip)
        local per = info.format == Texture.FORMAT_R8 and 1 or 4
        mip = math.min(mip, info.mips - 1)
        local w, h = math.max(1, bit.rshift(info.width, mip)), math.max(1, bit.rshift(info.height, mip))
        local data = ffi.new('uint8_t[?]', w * h * per)
        pixels((layer % info.layers) * info.layer_bytes + info.mip_offsets[mip], w * h * per, data, 0)
        local sum = 0
        for i = 0, w * h - 1 do
            local v = 100 * (data[i * per] / 255 - 0.5)
            if v > 1 then v = 1 elseif v < 0 then v = 0 end
            sum = sum + v
        end
        return sum / (w * h)
    end
    local function mask(format, width, height, mips, layers)
        local per = format == Texture.FORMAT_R8 and 1 or 4
        local info = {format = format, width = width, height = height, mips = mips, layers = layers, mip_offsets = {},
                      layer_bytes = 0}
        for m = 0, mips - 1 do
            info.mip_offsets[m] = info.layer_bytes
            info.layer_bytes = info.layer_bytes + math.max(1, bit.rshift(width, m)) * math.max(1, bit.rshift(height, m)) * per
        end
        local bytes = ffi.new('uint8_t[?]', info.layer_bytes * layers)
        for i = 0, info.layer_bytes * layers - 1 do bytes[i] = (i * 37 + math.floor(i / 7)) % 256 end
        local reads = 0
        local function pixels(at, size, out, out_offset)
            reads = reads + 1
            ffi.copy(out + (out_offset or 0), bytes + at, size)
        end
        return info, pixels, function() return reads end
    end
    local grower = Slim.grower(64)
    for _, c in ipairs({{Texture.FORMAT_R8, 256, 256, 9, 1, 2}, {Texture.FORMAT_RGBA8, 256, 256, 9, 2, 3},
                        {Texture.FORMAT_R8, 2048, 300, 1, 1, 0}, {Texture.FORMAT_RGBA8, 300, 70, 1, 1, 0},
                        {Texture.FORMAT_R8, 1, 1, 1, 1, 4}, {Texture.FORMAT_R8, 32768, 2, 1, 1, 0}}) do
        local info, pixels, reads = mask(c[1], c[2], c[3], c[4], c[5])
        local pauses = 0
        local got = Texture.mask_coverage(pixels, info, c[6], 2, grower, function() pauses = pauses + 1 end)
        local mip = math.min(2, c[4] - 1)
        local w, h = math.max(1, bit.rshift(c[2], mip)), math.max(1, bit.rshift(c[3], mip))
        local rows = math.max(1, math.floor(Texture.MASK_BLOCK / w))
        local blocks = math.ceil(h / rows)
        assert(got == whole(pixels, info, c[6], 2), string.format('%dx%d: %.17g', c[2], c[3], got))
        assert(pauses == blocks and reads() == blocks + 1, string.format('%dx%d: %d pauses, %d reads, %d blocks', c[2],
               c[3], pauses, reads() - 1, blocks))
    end
end)

check('R32G32B32A32_FLOAT (mods\' LUTs, user report 2026-10-08): singles decode exactly from their bytes (NaN as 0/0); '
      .. 'its header, mip sizes, LUTs, patterns, tilers and cape cells read', function()
    local function bytes_of(bits) -- the four little-endian bytes of a 32-bit pattern
        local p = ffi.new('uint8_t[4]')
        for k = 0, 3 do p[k] = math.floor(bits / 256 ^ k) % 256 end
        return p
    end
    local cases = {{0x3F800000, 1}, {0xC0200000, -2.5}, {0x00000001, 2 ^ -149}, {0x80000001, -2 ^ -149},
                   {0x007FFFFF, (2 ^ 23 - 1) * 2 ^ -149}, {0x7F7FFFFF, (2 - 2 ^ -23) * 2 ^ 127}, {0x00800000, 2 ^ -126},
                   {0x7F800000, math.huge}, {0xFF800000, -math.huge}, {0x3EAAAAAB, 0.3333333432674408}}
    for _, c in ipairs(cases) do
        local got = Texture.single(bytes_of(c[1]), 0)
        assert(got == c[2], string.format('%08x: %.17g', c[1], got))
    end
    local zero = Texture.single(bytes_of(0x80000000), 0)
    assert(zero == 0 and 1 / zero < 0, 'negative zero')
    for _, bits in ipairs({0x7FC00000, 0x7F800001, 0xFFFFFFFF, 0x7FA5A5A5}) do
        local nan = Texture.single(bytes_of(bits), 0)
        assert(type(nan) == 'number' and nan ~= nan, string.format('%08x: a NaN', bits))
    end
    -- every float a float array holds comes back from its bytes
    local f = ffi.new('float[1]')
    local view = ffi.cast('const uint8_t *', f)
    for i = 1, 2000 do
        f[0] = (i % 2 == 0 and -1 or 1) * (i * 7919 % 100003) / 997 * 2 ^ ((i % 60) - 30)
        assert(Texture.single(view, 0) == f[0], 'float ' .. i)
    end
    -- a 23 x 8 LUT with 3 mips: header, sizes, values
    local main = ffi.new('uint8_t[?]', 0xC0 + 148)
    local function put(o, v) for k = 0, 3 do main[o + k] = math.floor(v / 256 ^ k) % 256 end end
    put(0xC0, 0x20534444) put(0xC0 + 12, 8) put(0xC0 + 16, 23) put(0xC0 + 28, 3) put(0xC0 + 84, 0x30315844)
    put(0xC0 + 128, Texture.FORMAT_RGBA32F) put(0xC0 + 140, 1)
    local info = Texture.describe(main, 0xC0 + 148)
    assert(info.format == 2 and info.layer_bytes == (23 * 8 + 11 * 4 + 5 * 2) * 16 and info.mip_offsets[1] == 2944,
           'RGBA32F mip sizes: 16 bytes a texel')
    local floats = ffi.new('float[?]', info.total / 4)
    for i = 0, 23 * 8 * 4 - 1 do floats[i] = (i % 13) / 8 - 0.5 end
    ffi.copy(ffi.cast('uint8_t *', floats) + 7 * 4, bytes_of(0x7FA5A5A5), 4) -- a NaN with a payload in the LUT
    local raw = ffi.cast('const uint8_t *', floats)
    local function pixels(at, size, out, out_offset) ffi.copy(out + (out_offset or 0), raw + at, size) end
    local values, width, height = Texture.lut(pixels, info, Slim.grower(64))
    assert(width == 23 and height == 8, 'size')
    for i = 0, 23 * 8 * 4 - 1 do
        if i == 7 then
            assert(values[i] ~= values[i] and tonumber(values[i]) ~= nil, 'the NaN canonical')
        else
            assert(values[i] == (i % 13) / 8 - 0.5, 'value ' .. i)
        end
    end
    -- a tiler of floats reads as 8-bit channels (what the disk cache keeps); a format the samples cannot read raises
    info.width, info.height, info.mips, info.mip_offsets = 512, 1, 1, {[0] = 0}
    local tiler = ffi.new('float[2048]')
    for i = 0, 2047 do tiler[i] = (i % 300) / 255 - 0.1 end
    raw = ffi.cast('const uint8_t *', tiler)
    local samples = Texture.samples(pixels, info, 0, 512, Slim.grower(64))
    for i = 0, 2047 do
        local v = math.min(math.max((i % 300) / 255 - 0.1, 0), 1)
        assert(samples[0][i] == math.floor(tiler[i] < 0 and 0 or math.min(tiler[i], 1) * 255 + 0.5) / 255
               and math.abs(samples[0][i] - v) <= 0.5 / 255 + 1e-9, 'tiler value ' .. i)
    end
    info.format = Texture.FORMAT_R8
    assert(not pcall(Texture.samples, pixels, info, 0, 512, Slim.grower(64)), 'an R8 tiler raises')
end)

check('emblem sheets: a recipe whose prepared sheet something still holds is found again (three live capes, recipes '
      .. '1 2 3 1 2 3: three copies, not six); a dropped one beyond the two kept is made again', function()
    local size = 4096
    local original = Recolor.c_buffer(size)
    ffi.fill(original, size, 7)
    local copies = 0
    local ctx = {p = {sheet = function() return original end}, cape_kit = {archive = '0000000000000001'},
                 deps = {Capes = {recolor_sheet = function() copies = copies + 1 end,
                                  sheet_sums = function() return 0, 0 end}, Colour = {}}}
    local function recipe(color)
        return {name = '0000000000001234', width = 32, height = 32, mips = 1, size = size,
                cells = {{rect = {0, 0, 4, 4}, shift = {color, 0, 0}}}}
    end
    local held = {}
    for _, color in ipairs({1, 2, 3, 1, 2, 3}) do held[color] = Recolor.sheet_spec(ctx, recipe(color), function() end) end
    assert(copies == 3, 'three recipes, three copies: ' .. copies)
    for _, color in ipairs({1, 2, 3}) do
        assert(Recolor.sheet_spec(ctx, recipe(color), function() end) == held[color], 'the same spec ' .. color)
    end
    held = {}
    collectgarbage('collect') -- lint-ok: R4 test process only
    copies = 0
    Recolor.sheet_spec(ctx, recipe(4), function() end)
    Recolor.sheet_spec(ctx, recipe(5), function() end) -- 4 and 5 kept now
    Recolor.sheet_spec(ctx, recipe(1), function() end)
    assert(copies == 3, 'recipe 1, held by nothing and no longer kept, is made again: ' .. copies)
end)

check('ID-mask coverage reads mip 0 of the game\'s masks (at most 512 x 512) and of a mask without mips, else the first '
      .. 'mip no larger than 512 on either side (a mod\'s 2K or 4K mask), as a mask of that mip alone', function()
    local function mask(width, height, mips, layers)
        local info = {format = Texture.FORMAT_RGBA8, width = width, height = height, mips = mips, layers = layers,
                      mip_offsets = {}, layer_bytes = 0}
        for m = 0, mips - 1 do
            info.mip_offsets[m] = info.layer_bytes
            info.layer_bytes = info.layer_bytes + math.max(1, bit.rshift(width, m)) * math.max(1, bit.rshift(height, m)) * 4
        end
        local bytes = ffi.new('uint8_t[?]', info.layer_bytes * layers)
        for i = 0, info.layer_bytes * layers - 1 do bytes[i] = (i * 13 + math.floor(i / 11)) % 256 end
        local read = 0
        local function pixels(at, size, out, out_offset)
            read = read + size
            ffi.copy(out + (out_offset or 0), bytes + at, size)
        end
        return info, pixels, bytes, function() return read end
    end
    local grower = Slim.grower(64)
    -- the same texels as a one-mip mask of their own
    local function alone(info, bytes, m)
        local w, h = math.max(1, bit.rshift(info.width, m)), math.max(1, bit.rshift(info.height, m))
        local one = {format = info.format, width = w, height = h, mips = 1, layers = info.layers,
                     mip_offsets = {[0] = 0}, layer_bytes = w * h * 4}
        local copy = ffi.new('uint8_t[?]', one.layer_bytes * info.layers)
        for l = 0, info.layers - 1 do
            ffi.copy(copy + l * one.layer_bytes, bytes + l * info.layer_bytes + info.mip_offsets[m], one.layer_bytes)
        end
        return Texture.coverage(function(at, size, out, out_offset) ffi.copy(out + (out_offset or 0), copy + at, size) end,
                                one, Slim.grower(64))
    end
    for _, c in ipairs({{512, 512, 10, 2, 0}, {256, 512, 10, 1, 0}, {2048, 2048, 12, 2, 2}, {4096, 1024, 13, 1, 3},
                        {2048, 2048, 1, 1, 0}}) do
        local info, pixels, bytes, read = mask(c[1], c[2], c[3], c[4])
        local got = assert(Texture.coverage(pixels, info, grower))
        local want = alone(info, bytes, c[5])
        for k = 1, 4 * c[4] do
            assert(got[k] == want[k], string.format('%dx%d mip %d slot %d: %.17g vs %.17g', c[1], c[2], c[5], k, got[k], want[k]))
        end
        local w, h = math.max(1, bit.rshift(c[1], c[5])), math.max(1, bit.rshift(c[2], c[5]))
        assert(read() == w * h * 4 * c[4], string.format('%dx%d: only mip %d read (%d bytes)', c[1], c[2], c[5], read()))
    end
end)

check('half floats', function()
    local cases = {{0x00, 0x3C, 1}, {0x00, 0xC0, -2}, {0xFF, 0x7B, 65504}, {0x01, 0x00, 2 ^ -24},
                   {0x00, 0x7C, math.huge}, {0x00, 0x00, 0}, {0x00, 0x38, 0.5}, {0x55, 0x35, 0.333251953125}}
    for _, c in ipairs(cases) do assert(Texture.half(c[1], c[2]) == c[3], 'half ' .. c[3]) end
    local nan = Texture.half(0x01, 0x7C)
    assert(nan ~= nan, 'NaN')
end)

check('32-bit products are exact (the game\'s map hash)', function()
    for _, c in ipairs({{0xe5, 0x9E3779B1}, {0xFFFFFFFF, 0xFFFFFFFF}, {0x12345678, 0x9ABCDEF1}, {5, 3}}) do
        local exact = tonumber((ffi.cast('uint64_t', c[1]) * c[2]) % 4294967296ULL)
        assert(Avatar.low32_product(c[1], c[2]) == exact, string.format('%x * %x', c[1], c[2]))
    end
end)

-- A map in a byte table: {data at 0x10000, capacity, empty, multiplier} at 0x20000; probing as the game does.
local function fake_map(entries, capacity, multiplier)
    local memory = {}
    local function put32(address, value)
        for k = 0, 3 do memory[address + k] = math.floor(value / 256 ^ k) % 256 end
    end
    put32(0x20000, 0x10000) put32(0x20004, 0) put32(0x20008, capacity) put32(0x2000C, 0xFFFFFFFF)
    put32(0x20010, multiplier)
    for slot = 0, capacity - 1 do put32(0x10000 + 8 * slot, 0xFFFFFFFF) put32(0x10004 + 8 * slot, 0) end
    local used = {}
    for key, value in pairs(entries) do
        local slot = Avatar.low32_product(key, multiplier) % capacity
        while used[slot] do slot = (slot + 1) % capacity end
        used[slot] = true
        put32(0x10000 + 8 * slot, key) put32(0x10004 + 8 * slot, value)
    end
    local buffer = ffi.new('uint8_t[64]')
    return function(address, size)
        for k = 0, size - 1 do
            local b = memory[address + k]
            if b == nil then return nil end
            buffer[k] = b
        end
        return buffer
    end
end

check('map lookups probe like the game (collisions, absent keys, wrap-around)', function()
    local read = fake_map({[5] = 0, [21] = 7, [37] = 9, [15] = 3}, 16, 1)
    assert(Avatar.lookup(read, 0x20000, 5) == 0 and Avatar.lookup(read, 0x20000, 21) == 7)
    assert(Avatar.lookup(read, 0x20000, 37) == 9 and Avatar.lookup(read, 0x20000, 15) == 3)
    assert(Avatar.lookup(read, 0x20000, 6) == nil and Avatar.lookup(read, 0x20000, 53) == nil)
    local hashed = fake_map({[0xe5] = 2, [0x96] = 194}, 1024, 0x9E3779B1)
    assert(Avatar.lookup(hashed, 0x20000, 0xe5) == 2 and Avatar.lookup(hashed, 0x20000, 0x96) == 194)
end)

check('numpy summation order (sequential below 8 terms, eight lanes from 8)', function()
    local a = {1e16, 1, -1e16, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}
    assert(Colour.npsum(a, 3) == ((1e16 + 1) - 1e16), 'sequential')
    local r = {a[1] + a[9], a[2] + a[10], a[3] + a[11], a[4] + a[12], a[5], a[6], a[7], a[8]}
    local expected = ((r[1] + r[2]) + (r[3] + r[4])) + ((r[5] + r[6]) + (r[7] + r[8])) + a[13]
    assert(Colour.npsum(a, 13) == expected, 'pairwise')
end)

check('CIEDE2000 reference pairs (Sharma, Wu and Dalal 2005)', function()
    local pairs_ = {{50, 2.6772, -79.7751, 50, 0, -82.7485, 2.0425}, {50, 3.1571, -77.2803, 50, 0, -82.7485, 2.8615},
                    {50, -1.3802, -84.2814, 50, 0, -82.7485, 1.0000}, {50, 2.5, 0, 50, 0, -2.5, 4.3065},
                    {50, 0, 0, 50, -1, 2, 2.3669}, {60.2574, -34.0099, 36.2677, 60.4626, -34.1751, 39.4387, 1.2644},
                    {90.8027, -2.0831, 1.441, 91.1528, -1.6435, 0.0447, 1.4441}}
    for _, p in ipairs(pairs_) do
        local d = Colour.de2000(p[1], p[2], p[3], p[4], p[5], p[6])
        assert(math.abs(d - p[7]) < 1e-4, string.format('dE %.4f, expected %.4f', d, p[7]))
    end
end)

check('a mod\'s patches: a weighted piece\'s unit, material or mask makes the geometry patched (a weight-0 piece\'s '
      .. 'does not); a LUT row differs in color or in finish (review 2026-10-06)', function()
    local Kits, Appearance = require('kits'), require('appearance')
    local function lut(fill)
        local v = ffi.new('float[?]', 23 * 2 * 4)
        for i = 0, 23 * 2 * 4 - 1 do v[i] = fill end
        return {values = v, width = 23, height = 2}
    end
    local archived, modded = lut(0.5), lut(0.5)
    modded.values[(0 * 23 + 0) * 4 + 1] = 0.9 -- row 0: base color green channel: a color change
    modded.values[(1 * 23 + 6) * 4 + 3] = 1.0 -- row 1: metallic (column 6 w): a finish change
    local function analysis()
        return {pieces = {{piece = {path = 'u1'}, weight = 0.3, skin = false,
                           materials = {{material = 'm1', mask = 'k1', lut = 'aaaa'}}},
                          {piece = {path = 'u2'}, weight = 0.0, skin = false,
                           materials = {{material = 'm2', mask = 'k2', lut = 'aaaa'}}}},
                rows = {{key = 'aaaa:0', lut = 'aaaa', row = 0}, {key = 'aaaa:1', lut = 'aaaa', row = 1}},
                luts = {aaaa = modded}}
    end
    local colour = {row_info = function(_, _, r) return 50 + r, 1, 2, false, false, 0, false, 0.2, 0.3, 0.4 end}
    local function touched(list)
        local out = {}
        for _, k in ipairs(list) do out['0123456789abcdef ' .. k] = {file = 'x'} end
        return out
    end
    local a = Kits.mark_patched(analysis(), touched({'aaaa ' .. Kits.TYPE_TEXTURE}), function() return archived end,
                                colour)
    assert(not a.geometry_patched, 'a LUT mod leaves the geometry')
    assert(a.rows[1].finish_changed == false and a.rows[2].finish_changed == true, 'row 0 color, row 1 finish')
    assert(a.rows[1].vanilla.L == 50 and a.rows[2].vanilla.L == 51 and a.rows[1].vanilla.ag == 0.3, 'archived rows')
    for _, k in ipairs({'k1 ' .. Kits.TYPE_TEXTURE, 'm1 ' .. Kits.TYPE_MATERIAL, 'u1 ' .. Kits.TYPE_UNIT}) do
        assert(Kits.mark_patched(analysis(), touched({k}), function() return archived end, colour).geometry_patched,
               k .. ': the geometry is the mod\'s')
    end
    for _, k in ipairs({'k2 ' .. Kits.TYPE_TEXTURE, 'm2 ' .. Kits.TYPE_MATERIAL, 'u2 ' .. Kits.TYPE_UNIT}) do
        assert(not Kits.mark_patched(analysis(), touched({k}), function() return archived end, colour).geometry_patched,
               k .. ': a piece that adds no rows')
    end
    local same = Kits.mark_patched({pieces = {}, rows = {{key = 'aaaa:0', lut = 'aaaa', row = 0}},
                                    luts = {aaaa = lut(0.5)}}, touched({'aaaa ' .. Kits.TYPE_TEXTURE}),
                                   function() return archived end, colour)
    assert(same.rows[1].finish_changed == nil, 'a patched LUT row equal to the archived one is unchanged')
    -- what the matcher is given: no measurement for patched geometry; a native look on another record finds its own
    local data = {luts = {'aaaa', 'bbbb', 'cccc'}, rows = {'0 1 1 1 0 0 0', '0 1 1 1 0 0 0'},
                  kits = {['11111111'] = '1 2;1.0=100,50;', ['22222222'] = '3;3.0=10,5;', ['33333333'] = '3;3.0=20,9;'}}
    local look = Appearance.new(data)
    local rows = {{key = 'aaaa:0', lut = 'aaaa', row = 0}, {key = 'bbbb:0', lut = 'bbbb', row = 0}}
    local carrier = {kit = {id = 0x44444444}, rows = rows}
    assert(Recolor.look_of(carrier, look).kit == look.kit('11111111'), 'the look\'s own measurement, by its LUTs')
    assert(Recolor.look_of({kit = {id = 0x44444444}, rows = {{key = 'cccc:0', lut = 'cccc', row = 0}}}, look).kit == nil,
           'two kits with those LUTs: none')
    assert(Recolor.look_of({kit = {id = 0x11111111}, rows = rows, geometry_patched = true}, look).kit == nil,
           'patched geometry: no measurement')
    assert(Recolor.look_of({kit = {id = 0x11111111}, rows = rows}, look).kit == look.kit('11111111'), 'its own')
end)

check('a mod\'s LUT row keeps its measured response only while its finish is the archived one; its light follows '
      .. 'its new colors', function()
    local Appearance = require('appearance')
    local data = {luts = {'aaaa'}, rows = {'0 1 1 1 0 0 0|1 1 1 1 0 0 0'}, kits = {['11111111'] = '1;1.0=100,40 1.1=50,20;'}}
    local look = Appearance.new(data)
    local function rows()
        local base = {lut = 'aaaa', under = 0, metal = false, camo = false, mode = 0, full = false}
        local out = {}
        for r = 0, 1 do
            local row = {key = 'aaaa:' .. r, row = r, area = 0.5, L = 50, a = 0, b = 0, ar = 0.2, ag = 0.2, ab = 0.2}
            for k, v in pairs(base) do row[k] = v end
            out[#out + 1] = row
        end
        return out
    end
    local plain = Matcher.item(rows(), false, nil, Recolor.look_of({kit = {id = 0x11111111}, rows = rows()}, look))
    local changed = rows()
    changed[1].finish_changed, changed[1].vanilla = false, {L = 40, a = 0, b = 0, ar = 0.1, ag = 0.1, ab = 0.1}
    changed[2].finish_changed, changed[2].vanilla = true, {L = 40, a = 0, b = 0, ar = 0.1, ag = 0.1, ab = 0.1}
    local item = Matcher.item(changed, false, nil, Recolor.look_of({kit = {id = 0x11111111}, rows = changed}, look))
    assert(item.measured and plain.measured, 'both measured')
    assert(item.rows[1].cal ~= nil and item.rows[2].cal == nil and plain.rows[2].cal ~= nil,
           'a color change keeps the response, a finish change drops it')
    assert(math.abs(item.rows[1].light - 40 * 2) < 1e-9, 'light x 2: twice the albedo through a gain-1 response, '
           .. item.rows[1].light)
    assert(item.rows[2].light > 20 and plain.rows[2].light == 20, 'the finish-changed row brighter by the model')
end)

check('an item without a measurement of its own (a mod patched its geometry; a kit the study did not see) still uses '
      .. 'the study: a row no kit showed on 0.1% of its view weighs nothing unless a mod changed it, rows of LUTs the '
      .. 'study never measured keep their coverage, and rows take their measured response (end user 2026-10-08: a '
      .. 'hidden debug green became the armor\'s accent and every helmet\'s stripes)', function()
    local Appearance = require('appearance')
    -- kit 11111111 measured with LUTs aaaa and cccc (200,000 px: its rows' and its pattern's): aaaa row 0 seen on
    -- 99,995 px, row 1 on 5 (a sliver), row 2 never, no row of cccc seen; LUT bbbb is not in the study
    local data = {luts = {'aaaa', 'cccc'}, rows = {'0 1 1 1 0 0 0|1 1 1 1 0 0 0'},
                  kits = {['11111111'] = '1 2;1.0=99995,40 1.1=5,1;dddd=100000,1,1,1'}}
    local look = Appearance.new(data)
    assert(math.abs(look.seen_share('aaaa', 0) - 0.499975) < 1e-12 and look.seen_share('aaaa', 1) == 2.5e-5
           and look.seen_share('aaaa', 2) == 0 and look.seen_share('cccc', 0) == 0 and look.seen_share('bbbb', 0) == nil,
           'best shares of the kit\'s pixels, patterns included: seen, a sliver, never, a measured LUT never seen, not '
           .. 'studied')
    local function row(lut, r, area, L, a, b)
        return {key = lut .. ':' .. r, lut = lut, row = r, area = area, under = 0, L = L, a = a, b = b, ar = 0.2,
                ag = 0.2, ab = 0.2, metal = false, camo = false, mode = 0, full = false}
    end
    -- the armor: a grey main, the debug green hidden (3% of its texture), a red sliver, an orange of a LUT the study
    -- never measured
    local function armor(changed)
        local rows = {row('aaaa', 0, 0.80, 40, 0, 0), row('aaaa', 2, 0.03, 87, -86, 83), row('aaaa', 1, 0.03, 50, 70, 50),
                      row('bbbb', 0, 0.02, 65, 35, 60)}
        if changed then rows[2].vanilla = {L = 40, a = 0, b = 0, ar = 0.05, ag = 0.05, ab = 0.05} end
        local analysis = {kit = {id = 0x11111111, kit_type = 'Armor'}, rows = rows, geometry_patched = true}
        return Matcher.item(rows, true, nil, Recolor.look_of(analysis, look))
    end
    local s = armor()
    assert(not s.measured and s.rows[2].area == 0 and s.rows[3].area == 0 and s.rows[2].tex_area == 0.03,
           'the hidden row and the sliver weigh nothing (their coverage kept as tex_area)')
    assert(s.rows[4].area == 0.02 and s.rows[1].area == 0.80, 'a seen row and a row of an unmeasured LUT keep coverage')
    assert(s.rows[1].cal and math.abs(s.rows[1].L - 51.84) < 0.1 and not s.rows[4].cal,
           'the measured response gives the seen row its perceived color (albedo 0.2 through gain 1: L 51.8, model 40)')
    local helmet = Matcher.item({row('h', 0, 0.85, 30, 0, 0), row('h', 1, 0.15, 70, -5, 60)}, false)
    local plan = Matcher.plan(helmet, s)
    assert(plan['h:1'] and plan['h:1'].kind == 'accent' and plan['h:1'].source == 'bbbb:0',
           'the helmet\'s stripe takes the orange, not the hidden green: ' .. tostring(plan['h:1'] and plan['h:1'].source))
    local modded = armor(true)
    assert(modded.rows[2].area == 0.03, 'a row a mod changed may be in use: its coverage kept')
    -- a measured kit is unchanged: the hidden row has no pixels anyway, and the index is not made for it
    local built, index_seen = 0, look.index_seen
    look.index_seen = function(yield) built = built + 1 return index_seen(yield) end
    local measured_rows = {row('aaaa', 0, 0.80, 40, 0, 0), row('aaaa', 2, 0.03, 87, -86, 83)}
    local m = Matcher.item(measured_rows, true, nil,
                           Recolor.look_of({kit = {id = 0x11111111, kit_type = 'Armor'}, rows = measured_rows}, look))
    assert(m.measured and m.rows[2].area == 0 and m.rows[1].area == 99995, 'measured: pixels, as before')
    assert(built == 0, 'a measured item does not make the index')
    armor()
    assert(built == 1, 'an unmeasured item makes it (once made, a no-op)')
end)

check('a row 0 that ID-mask coverage leaves out (texels of blank weights draw row 0) takes its group\'s color and '
      .. 'weighs nothing even where the study saw it; a group nothing weighs looks like its rows, not black (image '
      .. 'review 2026-10-09: the PH-56 Jaguar\'s shin wraps kept their tan)', function()
    local Appearance = require('appearance')
    -- kit 22222222 measured with LUT aaaa: row 0 seen on 30,000 px, row 1 on 60,000, row 2 on 10,000
    local look = Appearance.new({luts = {'aaaa'}, rows = {'0 1 1 1 0 0 0|1 1 1 1 0 0 0|2 1 1 1 0 0 0'},
                                 kits = {['22222222'] = '1;1.0=30000,10 1.1=60000,30 1.2=10000,5;'}})
    local function row(r, area, L, a, b, lut)
        lut = lut or 'aaaa'
        return {key = lut .. ':' .. r, lut = lut, row = r, area = area, under = 0, L = L, a = a, b = b,
                ar = 0.1, ag = 0.08, ab = 0.05, metal = false, camo = false, mode = 0, full = false}
    end
    -- the wraps (row 0, no coverage) share the tan of the main cloth (row 1); a blue trim of no coverage stands alone
    local rows = {row(0, 0, 50, 5, 20), row(1, 0.7, 51, 5, 21), row(2, 0.3, 30, 0, 0), row(3, 0, 40, -10, -40)}
    local t = Matcher.item(rows, true, nil, Recolor.look_of({kit = {id = 0x22222222, kit_type = 'Armor'}, rows = rows},
                                                            look))
    assert(t.measured and t.rows[1].area == 0 and t.rows[2].area == 60000 and t.rows[1].tex_area == 0,
           'the wraps weigh nothing though seen; the cloth takes its pixels')
    local wraps, trim
    for _, g in ipairs(t.groups) do
        for _, r in ipairs(g.rows) do
            if r.key == 'aaaa:0' then wraps = g end
            if r.key == 'aaaa:3' then trim = g end
        end
    end
    assert(wraps and wraps.rows[1].key == 'aaaa:1', 'the wraps join the cloth\'s group by their model color')
    assert(trim.share == 0 and trim.L > 30, 'a group nothing weighs looks like its rows (L ' .. trim.L .. '), not black')
    local helmet = Matcher.item({row(0, 0.9, 35, 0, 0, 'hhhh'), row(1, 0.1, 20, 0, 0, 'hhhh')}, false)
    local plan = Matcher.plan(t, helmet)
    assert(plan['aaaa:0'] and plan['aaaa:1'] and plan['aaaa:0'].source == plan['aaaa:1'].source,
           'the wraps take the cloth\'s color')
end)

check('the study\'s index of seen rows is made in pieces, a pause every 32 kits, and kept only once whole (about 3 ms '
      .. 'outside the game, made in a job only for an item without a measurement)', function()
    local Appearance = require('appearance')
    local look = Appearance.new(require('appearance_data'))
    local pauses = 0
    local function counting() pauses = pauses + 1 coroutine.yield() end
    local dropped = coroutine.create(function() look.index_seen(counting) end)
    coroutine.resume(dropped) -- the first piece, then the job is dropped
    assert(pauses == 1, 'paused after the first 32 kits')
    pauses = 0
    local whole = coroutine.create(function() look.index_seen(counting) end)
    while coroutine.status(whole) ~= 'dead' do assert(coroutine.resume(whole)) end
    assert(pauses == 9, 'made anew from the first kit (nothing half-made kept), 293 kits: 9 pauses, ' .. pauses)
    pauses = 0
    look.index_seen(counting)
    assert(pauses == 0 and look.seen_share('19a4fb2cd5670ff2', 2) == 0
           and look.seen_share('19a4fb2cd5670ff2', 0) > 0.001, 'made once: the CE-27 Ground Breaker\'s debug green '
           .. 'never seen, its row 0 seen')
    -- the look of an item without a measurement makes it with the job's pauses
    local fresh = Appearance.new(require('appearance_data'))
    local job = coroutine.create(function()
        Recolor.look_of({kit = {id = 0x7edf6505, kit_type = 'Armor'}, rows = {}, geometry_patched = true}, fresh,
                        counting)
    end)
    while coroutine.status(job) ~= 'dead' do assert(coroutine.resume(job)) end
    assert(pauses == 9, 'look_of passes the job\'s pauses: ' .. pauses)
end)

check('overlapped reads: a pending read waits frames, a quick one none, a failure raises, an abandoned one is '
      .. 'cancelled and waited out before its handle closes', function()
    local Files = require('files')
    local calls, polls_left, last_error, read_size = {}, 0, 0, 0
    local fake = {}
    function fake.myc1_CreateFileW(_, _, _, _, _, flags) calls[#calls + 1] = 'open ' .. flags return ffi.cast('void *', 0x1234) end
    function fake.myc1_ReadFile(_, buffer, size, done, _)
        calls[#calls + 1] = 'read'
        read_size = size
        if size == 7 then last_error = 38 return 0 end -- end of file
        if polls_left < 0 then -- answered at once
            buffer[0] = 42
            if done ~= nil then done[0] = size end
            return 1
        end
        last_error = 997
        return 0
    end
    function fake.myc1_GetLastError() return last_error end
    function fake.myc1_GetOverlappedResult(_, _, done, wait)
        calls[#calls + 1] = 'poll ' .. wait
        if polls_left > 0 and wait == 0 then
            polls_left = polls_left - 1
            last_error = 996
            return 0
        end
        done[0] = read_size
        return 1
    end
    function fake.myc1_CancelIoEx() calls[#calls + 1] = 'cancel' return 1 end
    function fake.myc1_CloseHandle() calls[#calls + 1] = 'close' return 1 end

    local waits = 0
    local files = Files.new('fake/', nil, nil, function() waits = waits + 1 end, fake)
    local handle = files.open('a')
    assert(calls[1] == 'open ' .. (0x10000000 + 0x40000000), 'opened overlapped')
    local buffer = ffi.new('uint8_t[16]')
    polls_left = 2
    files.read(handle, 0, 16, buffer)
    assert(waits == 2 and files.waits == 2, 'two frames waited: ' .. waits)
    polls_left, waits = -1, 0
    files.read(handle, 0, 16, buffer)
    assert(waits == 0 and buffer[0] == 42, 'answered at once: no wait')
    assert(not pcall(files.read, handle, 0, 7, buffer), 'a failed read raises')
    -- a job dropped while its read is in flight
    polls_left, calls = 5, {}
    local co_files = Files.new('fake/', nil, nil, coroutine.yield, fake)
    local co = coroutine.create(function() co_files.read(handle, 0, 16, buffer) end)
    assert(coroutine.resume(co) and coroutine.status(co) == 'suspended', 'waiting on the disk')
    Files.settle()
    local seen = table.concat(calls, ',')
    assert(seen:find('cancel,poll 1', 1, true), 'cancelled, then waited out: ' .. seen)
    calls = {}
    co_files.close(handle)
    assert(table.concat(calls, ',') == 'close', 'closed once settled, no second cancel')
    local plain = Files.new('fake/', nil, nil, nil, fake)
    calls, polls_left = {}, -1
    plain.read(plain.open('b'), 0, 16, buffer)
    assert(calls[1] == 'open ' .. 0x10000000 and calls[2] == 'read' and #calls == 2, 'no wait: a plain read')
end)

check('a job dropped while it built a reader leaves no handle open: Files.abandon closes what job adapters hold, '
      .. 'once each, after settling a read in flight', function()
    local Files = require('files')
    local next_handle, open, closes = 0x5000, {}, 0
    local fake = {}
    function fake.myc1_CreateFileW()
        next_handle = next_handle + 8
        open[next_handle] = true
        return ffi.cast('void *', next_handle)
    end
    function fake.myc1_CloseHandle(handle)
        local n = tonumber(ffi.cast('intptr_t', handle))
        assert(open[n], 'closed once: ' .. n)
        open[n], closes = nil, closes + 1
        return 1
    end
    local function count() local n = 0 for _ in pairs(open) do n = n + 1 end return n end
    Files.abandon() -- nothing held: nothing happens
    local job = Files.new('fake/', nil, nil, coroutine.yield, fake)
    local a, b, c = job.open('a'), job.open('b'), job.open('c')
    job.close(b)
    local plain = Files.new('fake/', nil, nil, nil, fake) -- tests' and tools' adapters are not job adapters
    local mine = plain.open('d')
    assert(Files.held() == 2 and count() == 3, 'held: ' .. Files.held())
    Files.abandon()
    assert(Files.held() == 0 and count() == 1 and closes == 3, 'the two left open closed, the plain one kept')
    Files.abandon()
    assert(closes == 3, 'nothing closed twice')
    plain.close(mine)
    assert(count() == 0 and a and c, 'the plain adapter closes its own')
    -- a reader dropped (src/recolor.lua): its adapter closes later, a few handles at a time
    local reader = Files.new('fake/', nil, nil, coroutine.yield, fake)
    local handles = {}
    for i = 1, 5 do handles[i] = reader.open('r' .. i) end
    reader.close_later = true
    for _, handle in ipairs(handles) do reader.close(handle) end
    assert(count() == 5 and Files.held() == 0, 'queued: still open, no longer held')
    assert(Files.close_some(2) == 3 and count() == 3, 'two closed, three left')
    Files.abandon()
    assert(count() == 0 and closes == 3 + 1 + 5 and Files.close_some(4) == 0, 'the rest closed by Files.abandon, once')
end)

check('the idle watch reports a change once, then only real changes; the body-copy slot in one read when asked',
      function()
    local units = ffi.new('uint8_t[120]')
    local copies = ffi.new('uint8_t[2116]') -- count (+64) and 16 entries of 132 bytes (+68)
    local readable, reads, sizes = true, {}, {}
    local memory = {}
    function memory.read_into(address, size, out)
        local a = tonumber(ffi.cast('uintptr_t', address))
        reads[#reads + 1], sizes[#reads + 1] = a, size
        if a == 0x1000 then ffi.copy(out, units, size) return true end
        if a == 0x2000 + 64 and size <= 2116 and readable then ffi.copy(out, copies, size) return true end
        return false
    end
    local watch = Avatar.watch(memory, {units_at = 0x1000}, 0x2000)
    assert(watch.changed(true), 'first call')
    assert(not watch.changed(true) and not watch.changed(false), 'unchanged')
    reads = {}
    watch.changed(false)
    assert(#reads == 1 and reads[1] == 0x1000, 'without the slot: one read')
    reads = {}
    watch.changed(true)
    assert(#reads == 2 and reads[2] == 0x2040, 'with the slot: one more read, count and entries together')
    units[5] = 1
    assert(watch.changed(false) and not watch.changed(true), 'unit change, once')
    copies[0] = 1 -- an entry appears
    assert(not watch.changed(false), 'the slot is not read on this frame')
    assert(watch.changed(true) and not watch.changed(true), 'entry appears, once')
    copies[4 + 20] = 7 -- the entry's units change
    assert(watch.changed(true) and not watch.changed(true), 'entry changes, once')
    copies[4 + 132 + 20] = 9 -- bytes past the entries in use do not count
    assert(not watch.changed(true), 'unused entry bytes')
    readable = false
    assert(watch.changed(true) and watch.changed(true), 'an unreadable slot counts as a change')
    readable, copies[0] = true, 0
    assert(watch.changed(true) and not watch.changed(true), 'entry gone')
    -- 2026-10-17: the slot read covers the count and the entries in use at the last read (4 bytes while empty); a
    -- count that grew is read again in full on that frame, once
    reads, sizes = {}, {}
    watch.changed(true)
    assert(#reads == 2 and sizes[2] == 4, 'empty slot: the count alone, ' .. tostring(sizes[2]))
    copies[0] = 2
    reads, sizes = {}, {}
    assert(watch.changed(true), 'two entries appear')
    assert(#reads == 3 and sizes[2] == 4 and sizes[3] == 2116, 'grown: the whole slot read again on that frame')
    reads, sizes = {}, {}
    assert(not watch.changed(true) and #reads == 2 and sizes[2] == 4 + 2 * 132, 'then the two entries in use')
    copies[0] = 1
    reads, sizes = {}, {}
    assert(watch.changed(true) and #reads == 2, 'shrunk: no second read')
    assert(not watch.changed(true) and sizes[#sizes] == 4 + 132, 'then one entry')
end)

-- A color model over flat tiler samples (every texel 0.5: no detail, no camo pattern), so a row's albedo is its
-- base color unless its detail strength or roughness bias (column 1 z, w) says otherwise.
local function flat_model()
    local function layers(n)
        local out = {}
        for l = 0, n - 1 do
            local values = ffi.new('double[2048]')
            for i = 0, 2047 do values[i] = 0.5 end
            out[l] = values
        end
        return out
    end
    return Colour.new(layers(26), 26, layers(5), 5)
end

-- One LUT row (23 columns) as Colour.row_values gives it: material columns get marker values.
local function test_row()
    local c = {}
    for k = 1, 92 do c[k] = 100 + k end
    local function set(column, r, g, b, w) c[column * 4 + 1], c[column * 4 + 2], c[column * 4 + 3], c[column * 4 + 4] = r, g, b, w end
    set(0, 0.5, 0.2, 0.2, 0)      -- red base, mode 0
    set(1, 3, 0.5, 0, 0)          -- detail layer 3, no detail strength or roughness bias
    set(2, 0.52, 0.22, 0.2, 1)    -- detail color near the base: moves
    set(5, 0.95, 0.95, 0.95, 2)   -- white wear (bare metal): stays
    set(6, 0.45, 0.18, 0.18, 0.25) -- wear color near the base: moves; metallic 0.25
    set(21, 0, 0, 0, -1)          -- no camo
    return c
end

check('the transfer reaches the desired color and keeps every material column and distant wear color', function()
    local model = flat_model()
    local transfer = Transfer.new(Colour, model)
    local c, before = test_row(), test_row()
    -- desired: sRGB (0.2, 0.4, 0.6) seen through metallic 0.25
    local lin = function(x) return ((x * 0.947867 + 0.052133) ^ 2.4) end
    local dark = 1 - 0.55 * 0.25
    local L, a, b = Colour.linear_to_lab(lin(0.2) * dark, lin(0.4) * dark, lin(0.6) * dark)
    local gL, ga, gb, err = transfer.fit(c, L, a, b)
    assert(err < Transfer.FIT_DONE and Colour.de2000(gL, ga, gb, L, a, b) == err, 'reached: dE ' .. err)
    assert(math.abs(c[1] - 0.2) < 0.01 and math.abs(c[2] - 0.4) < 0.01 and math.abs(c[3] - 0.6) < 0.01, 'base')
    local moved = {[1] = true, [2] = true, [3] = true, [9] = true, [10] = true, [11] = true, [25] = true, [26] = true,
                   [27] = true}
    for k = 1, 92 do
        if moved[k] then
            assert(c[k] ~= before[k], 'color ' .. k .. ' moved')
        else
            assert(c[k] == before[k], 'value ' .. k .. ' kept')
        end
    end
end)

check('camo rows move their camo colors; an unreachable goal keeps the best step', function()
    local transfer = Transfer.new(Colour, flat_model())
    local c = test_row()
    c[85], c[86], c[87], c[88] = 1, 0, 1, 2 -- camo layer 2
    for column = 16, 19 do c[column * 4 + 1], c[column * 4 + 2], c[column * 4 + 3] = 0.3, 0.3 + column / 100, 0.3 end
    local before = test_row()
    local _, _, _, err = transfer.fit(c, 100, 120, 120) -- outside the displayable range
    assert(err > Transfer.FIT_DONE and err < math.huge, 'best step kept: dE ' .. err)
    for column = 16, 19 do assert(c[column * 4 + 2] ~= 0.3 + column / 100, 'camo color ' .. column .. ' moved') end
    for _, k in ipairs({5, 6, 7, 8, 13, 14, 15, 16, 41}) do assert(c[k] == before[k], 'material value ' .. k) end
    local d = test_row()
    local _, _, _, nan_err = transfer.fit(d, 0 / 0, 0, 0)
    assert(nan_err == math.huge and d[1] == 0.5 and d[2] == 0.2, 'a NaN goal leaves the row unchanged')
end)

check('a job\'s transfer pauses after every perceived-color evaluation of a fit: same colors as without pauses',
      function()
    local pauses = 0
    local paused = Transfer.new(Colour, flat_model(), function() pauses = pauses + 1 end)
    local plain = Transfer.new(Colour, flat_model())
    local a, b = test_row(), test_row()
    local _, _, _, err_a = paused.fit(a, 100, 120, 120) -- unreachable: every step runs
    local _, _, _, err_b = plain.fit(b, 100, 120, 120)
    assert(pauses == Transfer.FIT_STEPS + 1, 'a pause after the first look and after each step: ' .. pauses)
    assert(err_a == err_b, 'the same fit')
    for k = 1, #a do assert(a[k] == b[k], 'value ' .. k) end
end)

check('camo colors toward a colored goal become shades of it: a green camo toward a yellow-green goal never lime or '
      .. 'lavender, toward a blue one never cyan or lilac (image review 2026-10-09)', function()
    local transfer = Transfer.new(Colour, flat_model())
    local function camo_hues(goal_L, goal_a, goal_b)
        local c = test_row()
        c[1], c[2], c[3] = 0.25, 0.35, 0.15 -- a green paint
        c[85], c[86], c[87], c[88] = 1, 0, 1, 2 -- camo layer 2
        local camo = {{0.20, 0.32, 0.12}, {0.40, 0.45, 0.20}, {0.35, 0.28, 0.18}, {0.42, 0.42, 0.40}} -- greens, a brown,
        for k, rgb in ipairs(camo) do                                                                  -- a near grey
            local o = (15 + k) * 4
            c[o + 1], c[o + 2], c[o + 3] = rgb[1], rgb[2], rgb[3]
        end
        transfer.fit(c, goal_L, goal_a, goal_b)
        local goal_h = math.deg(math.atan2(goal_b, goal_a))
        local worst = 0
        for column = 16, 19 do
            local o = column * 4
            local _, a, b = Colour.srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])
            if math.sqrt(a * a + b * b) > 3 then
                local d = math.abs(math.deg(math.atan2(b, a)) - goal_h) % 360
                worst = math.max(worst, d > 180 and 360 - d or d)
            end
        end
        return worst
    end
    local yellow = camo_hues(60, -6, 50)   -- the Light of Eternal Liberty's yellow
    local blue = camo_hues(54, 3, -22)     -- the SEAF blue
    assert(yellow < 3 and blue < 3, string.format('camo hues off the goal: %.1f and %.1f degrees', yellow, blue))
end)

check('a red paint going neutral leaves no tint: its neutral detail color stays neutral (the brown Bloodhound)', function()
    local transfer = Transfer.new(Colour, flat_model())
    local c = test_row()
    c[9], c[10], c[11] = 0.2, 0.2, 0.2   -- detail color: a dark neutral near the red base
    c[25], c[26], c[27] = 0.6, 0.3, 0.3  -- wear color: a lighter red of the same hue family
    local _, _, _, err = transfer.fit(c, 26, 0, 0)
    assert(err < Transfer.FIT_DONE, 'reached: dE ' .. err)
    for _, o in ipairs({0, 8, 24}) do -- base, detail, wear: neutral now (v11.0 turned the detail color teal)
        local _, a, b = Colour.srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])
        assert(math.sqrt(a * a + b * b) < 1.5, 'color at ' .. o .. ' is neutral: a ' .. a .. ', b ' .. b)
    end
    assert(c[21] == 0.95 and c[22] == 0.95 and c[23] == 0.95, 'the white wear color far from the paint stays')
end)

check('a paint that darkens by DARKEN_FOLLOW_L or more takes its neutral detail color along: a cream shell matched '
      .. 'to black kept its grey detail and its scuffs read as grime (the IX-VOIDWALKER on the B-01 Tactical, image '
      .. 'review 2026-10-09); a smaller change keeps it', function()
    local transfer = Transfer.new(Colour, flat_model())
    local function shell()
        local c = test_row()
        c[1], c[2], c[3] = 0.70, 0.67, 0.62  -- cream base
        c[9], c[10], c[11] = 0.44, 0.41, 0.40 -- a grey detail color, far from the cream (stays without the rule)
        return c
    end
    local detail_L = Colour.srgb_to_lab(0.44, 0.41, 0.40)
    local dark = shell()
    transfer.fit(dark, 22, 0, 0)
    local after = Colour.srgb_to_lab(dark[9], dark[10], dark[11])
    assert(after < detail_L - 20, string.format('to black: the detail follows (L %.1f -> %.1f)', detail_L, after))
    local mid = shell()
    transfer.fit(mid, 60, 0, 0)
    assert(mid[9] == 0.44 and mid[10] == 0.41 and mid[11] == 0.40, 'a smaller change keeps the detail color')
end)

check('a light glossy paint turned dark takes its source row\'s roughness (Transfer.DARK_L): the IX-VOIDWALKER\'s '
      .. 'white shell turned black kept its gloss, which showed its scuffs as grey-white marbled grime (independent '
      .. 'image reviews 2026-10-09); not when it stays light, from cloth or a smoother source, or under a flat role '
      .. 'color. Its color is fitted through the model then, not its glossy measured response, whose reflection floor '
      .. 'drove the color to black (user 2026-10-09: the Winter Warrior and Trench Paramedic helmets on the B-01 '
      .. '"way too dark relative to the armor")', function()
    local transfer = Transfer.new(Colour, flat_model())
    local base_L
    local function roughness(goal, source_row, grey)
        local function lut(row)
            local values = ffi.new('float[?]', 23 * 4)
            for k = 1, 92 do values[k - 1] = row[k] end
            return {values = values, width = 23, height = 1}
        end
        local shell = test_row()
        shell[1], shell[2], shell[3] = 0.70, 0.67, 0.62 -- a cream shell
        if grey then shell[1], shell[2], shell[3] = grey, grey, grey end
        shell[28], shell[33], shell[41] = 0, 0.2, 0.2   -- not metal, a hard paint, glossy
        local target = {luts = {aaaaaaaaaaaaaaaa = lut(shell)}}
        local source = {luts = {bbbbbbbbbbbbbbbb = lut(source_row)}}
        goal.kind, goal.source = goal.kind or 'pair', 'bbbbbbbbbbbbbbbb:0'
        local data = Recolor.build_luts(target, {['aaaaaaaaaaaaaaaa:0'] = goal}, transfer, function() end, source)
        local d = data.aaaaaaaaaaaaaaaa.data
        base_L = Colour.srgb_to_lab(d[0], d[1], d[2])
        return d[40]
    end
    local function black(rough, cloth)
        local row = test_row()
        row[1], row[2], row[3], row[28], row[41] = 0.05, 0.05, 0.05, 0, rough
        row[4], row[33] = cloth and 1 or 0, cloth and 0 or 0.3
        return row
    end
    local function near(x, y) return math.abs(x - y) < 1e-6 end
    assert(near(roughness({L = 20, a = 0, b = 0}, black(0.7)), 0.7), 'to black: the black\'s matte finish')
    assert(near(roughness({L = 45, a = 0, b = 0}, black(0.7)), 0.2), 'a smaller darkening keeps the gloss')
    assert(near(roughness({L = 35, a = 0, b = 0}, black(0.7)), 0.2), 'a dark grey (L 35) keeps the gloss')
    assert(near(roughness({L = 20, a = 0, b = 0}, black(0.7), 0.42), 0.2), 'a mid grey shell (L 45) to L 20 keeps it')
    assert(near(roughness({L = 20, a = 0, b = 0}, black(0.9, true)), 0.2), 'a cloth source gives no finish')
    assert(near(roughness({L = 20, a = 0, b = 0}, black(0.1)), 0.2), 'a glossier source never makes it glossier')
    assert(near(roughness({L = 20, a = 0, b = 0, all = true}, black(0.7)), 0.2), 'a flat role color keeps its finish')
    -- a glossy response whose reflection floor (0.072, the IX-VOIDWALKER shell's) alone shows L 32; the plan's goal
    -- counts the row's own gloss over the diffuse color it asks (src/matcher.lua diffuse_colors): diffuse L 20 here
    local glossy = {0.65, 0.62, 0.61, 0.072, 0.072, 0.072}
    local function with_floor(L, s)
        local y = Colour.lab_to_linear(L, 0, 0) + s
        return (Colour.linear_to_lab(y, y, y))
    end
    roughness({L = with_floor(20, 0.072), a = 0, b = 0, cal = glossy}, black(0.7))
    assert(base_L > 12, string.format('matte: the color carries the lightness (base L %.1f)', base_L))
    -- through its gain without its gloss floor, at the goal less that gloss (Transfer.diffuse_goal): the floor was
    -- measured at its own gloss; the gain still counts (through the model the paint came out darker by it)
    roughness({L = 20, a = 0, b = 0, cal = {0.65, 0.62, 0.61, 0, 0, 0}}, black(0.7))
    local gain_L = base_L
    roughness({L = with_floor(20, 0.01), a = 0, b = 0, cal = {0.65, 0.62, 0.61, 0.01, 0.01, 0.01}}, black(0.7))
    assert(math.abs(base_L - gain_L) < 0.01, string.format('a glossy response without its floor under the dark finish: '
           .. 'base L %.2f, through its gain alone %.2f', base_L, gain_L))
    roughness({L = 20, a = 0, b = 0}, black(0.7))
    assert(gain_L > base_L + 3, string.format('its gain counts: base L %.2f, through the model %.2f', gain_L, base_L))
    -- still glossy (no dark finish from a glossier source): through its response, its paint carries the diffuse color
    roughness({L = with_floor(20, 0.072), a = 0, b = 0, cal = glossy}, black(0.1))
    assert(base_L > 12, string.format('still glossy: its color carries the lightness (base L %.1f)', base_L))
end)

-- Exact bits of a number, -0 and NaN included.
local function bits(x) return string.format('%a', x) end

check('albedo linearizes each distinct sample color once and gives the same bits as shading every sample (v1.3): rows '
      .. 'with a detail layer (repeated and distinct sample controls), without one (every sample alike) and with camo, '
      .. 'and again once the layer\'s distinct samples are known (KB match-your-colors-stress-test)', function()
    local seed = 12345
    local function random()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    local detail, camo = {}, {}
    for l = 0, 25 do
        local values = ffi.new('double[2048]')
        for i = 0, 511 do
            values[i * 4], values[i * 4 + 1] = random(), random()
            if l == 25 then -- every sample its own controls
                values[i * 4 + 2], values[i * 4 + 3] = i / 511, (511 - i) / 511
            else -- few distinct pairs, one w under several z
                values[i * 4 + 2], values[i * 4 + 3] = ((i * (l + 3)) % 9) / 8, ((i * (l + 5)) % 7) / 6
            end
        end
        detail[l] = values
    end
    for l = 0, 4 do
        local values = ffi.new('double[2048]')
        for i = 0, 2047 do values[i] = random() end
        camo[l] = values
    end
    local function clip(x) return math.min(math.max(x, 0), 1) end
    local lin = Colour.srgb_to_linear
    local function camo_sample(c, s, i, md0, md1) -- v1.3's, as src/colour.lua has it
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
    local function reference(c) -- v1.3's albedo: every sample shaded and linearized
        local d = c[4] <= 3.0 and detail[c[5] % 26] or nil
        local s = c[88] >= 0.0 and camo[c[88] % 5] or nil
        local sum_r, sum_g, sum_b = 0, 0, 0
        for i = 0, 511 do
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
            sum_r, sum_g, sum_b = sum_r + lin(r), sum_g + lin(g), sum_b + lin(b)
        end
        return sum_r / 512, sum_g / 512, sum_b / 512
    end
    local model = Colour.new(detail, 26, camo, 5)
    local kinds = {}
    for n = 1, 90 do
        local c = {}
        for k = 1, 92 do c[k] = random() * 1.4 - 0.2 end
        c[4] = ({0, 2, 3, 3.5, 5, 1})[n % 6 + 1] -- a mode over 3: no detail layer
        c[5] = n % 26
        c[88] = n % 4 == 0 and n % 5 or -1
        local kind = c[88] >= 0 and 'camo' or (c[4] <= 3 and 'detail' or 'flat')
        kinds[kind] = (kinds[kind] or 0) + 1
        local r0, g0, b0 = reference(c)
        for pass = 1, 2 do
            local r, g, b = model.albedo(c)
            assert(bits(r) == bits(r0) and bits(g) == bits(g0) and bits(b) == bits(b0),
                   string.format('row %d (%s), pass %d: %s %s %s against %s %s %s', n, kind, pass, bits(r), bits(g),
                                 bits(b), bits(r0), bits(g0), bits(b0)))
        end
    end
    assert(kinds.camo > 10 and kinds.detail > 10 and kinds.flat > 10, 'every kind of row')
end)

check('Transfer.apply with the row\'s origin (its own albedo kept per origin and row) writes the same bits as without '
      .. 'one, again once kept, rows 0 and 1, a dark finish\'s row too (KB match-your-colors-stress-test)', function()
    local kept, plain = Transfer.new(Colour, flat_model()), Transfer.new(Colour, flat_model())
    local function shell(r, g, b)
        local row = test_row()
        row[1], row[2], row[3] = r, g, b
        row[28], row[33], row[41] = 0, 0.2, 0.2 -- not metal, a hard paint, glossy
        return row
    end
    local function lut(rows)
        local values = ffi.new('float[?]', 23 * 4 * #rows)
        for n, row in ipairs(rows) do
            for k = 1, 92 do values[(n - 1) * 92 + k - 1] = row[k] end
        end
        return {values = values, width = 23, height = #rows}
    end
    local black = test_row()
    black[1], black[2], black[3], black[28], black[41], black[4], black[33] = 0.05, 0.05, 0.05, 0, 0.7, 0, 0.3
    local source = {luts = {bbbbbbbbbbbbbbbb = lut({black})}}
    local rows = {shell(0.70, 0.67, 0.62), shell(0.30, 0.45, 0.62)}
    local origin = lut(rows)
    local glossy = {0.65, 0.62, 0.61, 0.072, 0.072, 0.072}
    local goals = {{L = 20, a = 0, b = 0, kind = 'pair', source = 'bbbbbbbbbbbbbbbb:0'}, -- the dark finish
                   {L = 45, a = 3, b = -4, kind = 'pair', source = 'bbbbbbbbbbbbbbbb:0'},
                   {L = 50, a = 20, b = 10, cal = glossy, kind = 'pair', source = 'bbbbbbbbbbbbbbbb:0'},
                   {L = 30, a = -5, b = 8, all = true}}
    local finished = 0
    for g, goal in ipairs(goals) do
        for pass = 1, 2 do
            for row = 0, 1 do
                local a, b = lut(rows), lut(rows)
                local err_a = kept.apply(a.values, 23, row, goal, source, origin)
                local err_b = plain.apply(b.values, 23, row, goal, source)
                assert(bits(err_a) == bits(err_b), string.format('goal %d, pass %d, row %d: error', g, pass, row))
                for i = 0, 2 * 92 - 1 do
                    assert(bits(a.values[i]) == bits(b.values[i]),
                           string.format('goal %d, pass %d, row %d: value %d %s against %s', g, pass, row, i,
                                         bits(a.values[i]), bits(b.values[i])))
                end
                if math.abs(a.values[row * 92 + 40] - 0.7) < 1e-6 then finished = finished + 1 end
            end
        end
    end
    assert(finished >= 2, 'the dark finish was taken: ' .. finished)
end)

check('a fit through a measured response that misses its goal by Transfer.RESPONSE_MISS or more is done through the '
      .. 'model (gallery 2026-10-10: the I-44 Salamander\'s bare-metal plates, response 0.19, went to a pale cream '
      .. 'L 98 under the Light of Eternal Liberty cape\'s yellow); a goal the response reaches keeps it', function()
    local transfer = Transfer.new(Colour, flat_model())
    local function fitted(cal, goal)
        local row = test_row()
        row[1], row[2], row[3], row[28], row[33] = 0.42, 0.42, 0.42, 0, 0.3 -- a grey hard paint
        local values = ffi.new('float[?]', 23 * 4)
        for k = 1, 92 do values[k - 1] = row[k] end
        local err = transfer.apply(values, 23, 0, {L = goal[1], a = goal[2], b = goal[3], cal = cal, kind = 'pair'})
        return {Colour.srgb_to_lab(values[0], values[1], values[2])}, err
    end
    local dim = {0.19, 0.19, 0.19, 0, 0, 0}
    local lab, err = fitted(dim, {59, -7, 50})
    assert(lab[1] < 90 and math.sqrt(lab[2] ^ 2 + lab[3] ^ 2) > 45,
           string.format('a dim response asked a yellow: the model\'s base L %.1f a %.1f b %.1f', lab[1], lab[2], lab[3]))
    assert(err < Transfer.RESPONSE_MISS, string.format('its error through the model: %.1f', err))
    -- a neutral goal it misses: through the model at the goal less the gloss its response shows (Transfer.diffuse_goal)
    local glossy_dim = {0.19, 0.19, 0.19, 0.1, 0.1, 0.1}
    local grey = fitted(glossy_dim, {70, 0, 0})
    local want = Transfer.diffuse_goal(Colour, {L = 70, a = 0, b = 0, cal = glossy_dim})
    assert(math.abs(grey[1] - want) < 1.5 and want < 65, string.format('the refit\'s base L %.1f, the goal less its '
           .. 'gloss L %.1f', grey[1], want))
    local reached, reached_err = fitted({0.6, 0.6, 0.6, 0, 0, 0}, {40, 0, 0})
    assert(reached_err < 1 and reached[1] > 45, string.format('a reachable goal keeps its response (a lighter paint '
           .. 'for its 0.6): base L %.1f, error %.1f', reached[1], reached_err))
end)

check('a fit through a measured response toward a colored goal under its floor (the look of black paint) that turns '
      .. 'its paint Transfer.FLOOR_TURN degrees or more off the goal\'s hue is done through the model (gallery '
      .. '2026-10-11, case 33: the UF-16 Inspector\'s red cloth sleeve under a navy cape took a near-black purple paint '
      .. 'and read purple); above its floor a turned paint keeps its response', function()
    local model = flat_model()
    local transfer = Transfer.new(Colour, model)
    local function fitted(cal, goal)
        local row = test_row()
        row[4], row[33] = 1, 0 -- cloth (mode 1, column 8 x at 0): its look counts its whole gloss floor
        local values = ffi.new('float[?]', 23 * 4)
        for k = 1, 92 do values[k - 1] = row[k] end
        transfer.apply(values, 23, 0, {L = goal[1], a = goal[2], b = goal[3], cal = cal, kind = 'pair'})
        local _, pa, pb = Colour.linear_to_lab(model.albedo(Colour.row_values(values, 23, 0)))
        local d = math.abs(math.deg(math.atan2(pb, pa) - math.atan2(goal[3], goal[2]))) % 360
        return {Colour.srgb_to_lab(values[0], values[1], values[2])}, math.min(d, 360 - d)
    end
    -- the sleeve's response: gain 1.15, a cyan sheen of L 19.2; through it the fit took paint L 0.7 a 4.4 b -10.3
    local cyan = {1.145, 1.148, 1.156, 0.0101, 0.0326, 0.0357}
    local navy = {L = 17.4, a = -3.8, b = -10.4, cal = cyan}
    local base = fitted(cyan, {navy.L, navy.a, navy.b})
    local want = {Transfer.diffuse_goal(Colour, navy)}
    local off = math.sqrt((base[1] - want[1]) ^ 2 + (base[2] - want[2]) ^ 2 + (base[3] - want[3]) ^ 2)
    assert(off < 2.5 and base[1] > 5 and base[2] < 2, string.format('the navy goal through the model at L %.1f a %.1f '
           .. 'b %.1f: base L %.1f a %.1f b %.1f', want[1], want[2], want[3], base[1], base[2], base[3]))
    -- a salmon above a green sheen (L 32.8): its paint turned 33 degrees to cancel the sheen keeps its response
    local kept, turn = fitted({1, 1, 1, 0.01, 0.10, 0.01}, {45, 20, 10})
    assert(turn >= Transfer.FLOOR_TURN and kept[2] > 35, string.format('above its floor the response\'s paint: base L '
           .. '%.1f a %.1f b %.1f, turned %.0f degrees', kept[1], kept[2], kept[3], turn))
end)

check('a fit through the model (the dark finish, a missed response) aims at the goal less the gloss the row\'s own '
      .. 'response shows at it: the plan\'s goal counts the target\'s highlights (Matcher diffuse_colors), which through '
      .. 'the model would turn into paint; a band\'s goal is a paint already', function()
    local cal = {0.6, 0.6, 0.6, 0.05, 0.05, 0.05}
    local L, a, b = Transfer.diffuse_goal(Colour, {L = 40, a = 0, b = 0, cal = cal})
    local y = Colour.lab_to_linear(40, 0, 0) - 0.05
    assert(math.abs(L - Colour.linear_to_lab(y, y, y)) < 1e-3 and math.abs(a) < 1e-3 and math.abs(b) < 1e-3,
           string.format('a neutral goal less its whole floor: L %.2f', L))
    local cL, _, cb = Transfer.diffuse_goal(Colour, {L = 50, a = 10, b = 25, cal = cal})
    assert(math.abs(cL - 50) < 1e-4 and math.abs(cb - 25) < 1e-4, 'a colored goal (chroma 20 or more) keeps all of it')
    assert(Transfer.diffuse_goal(Colour, {L = 40, a = 0, b = 0, cal = cal, band = true}) == 40, 'a band\'s paint as it is')
    assert(Transfer.diffuse_goal(Colour, {L = 40, a = 0, b = 0}) == 40, 'no response: the goal')
end)

check('an accent band\'s row (goal.band) is one coat of the accent\'s paint, fitted through the model: every following '
      .. 'color takes it (user 2026-10-10: the IX-VOIDWALKER\'s band "doesn\'t match the armor\'s own accenting", '
      .. 'its detail colors lime and light grey)', function()
    local transfer = Transfer.new(Colour, flat_model())
    local row = test_row()
    row[1], row[2], row[3], row[28], row[33] = 0.33, 0.50, 0.67, 0, 0.5 -- a navy base
    row[9], row[10], row[11] = 0.17, 0.21, 0.30                         -- a darker navy detail
    row[21], row[22], row[23], row[25], row[26], row[27] = 0.26, 0.36, 0.5, 0.3, 0.4, 0.55 -- navy wear
    local values = ffi.new('float[?]', 23 * 4)
    for k = 1, 92 do values[k - 1] = row[k] end
    transfer.apply(values, 23, 0, {L = 72.9, a = 1.7, b = 62.7, cal = {0.52, 0.51, 0.52, 0.004, 0.006, 0.006},
                                   kind = 'pair', band = true})
    for _, column in ipairs({2, 5, 6}) do
        for ch = 0, 2 do
            assert(math.abs(values[column * 4 + ch] - values[ch]) < 1e-9, 'column ' .. column .. ' takes the base')
        end
    end
    local L, a, b = Colour.srgb_to_lab(values[0], values[1], values[2])
    assert(math.abs(L - 72.9) < 2 and math.abs(b - 62.7) < 3,
           string.format('the paint itself, not its look through the response: L %.1f a %.1f b %.1f', L, a, b))
end)

check('a flat role color (SEAF, goal.all): no colored detail or wear color stays or turns rigidly; rust flecks go '
      .. 'grey on the uniform, brown straps take the blue, an olive camo plate\'s brown wear never turns magenta '
      .. '(independent image review 2026-10-09)', function()
    local transfer = Transfer.new(Colour, flat_model())
    local function hue_of(c, o)
        local _, a, b = Colour.srgb_to_lab(c[o + 1], c[o + 2], c[o + 3])
        return math.deg(math.atan2(b, a)) % 360, math.sqrt(a * a + b * b)
    end
    local function gap(h1, h2)
        local d = math.abs(h1 - h2) % 360
        return d > 180 and 360 - d or d
    end
    -- a tan cloth with a rust detail color of another hue (off the paint's family: kept without all) toward the grey
    local function tan_cloth()
        local c = test_row()
        c[1], c[2], c[3] = 0.62, 0.55, 0.42  -- tan base
        c[9], c[10], c[11] = 0.55, 0.22, 0.30 -- a rust-magenta detail color, far from the tan's hue
        return c
    end
    local kept, flat = tan_cloth(), tan_cloth()
    transfer.fit(kept, 40, 0, 0)
    transfer.fit(flat, 40, 0, 0, nil, nil, true)
    local _, kept_c = hue_of(kept, 8)
    local _, flat_c = hue_of(flat, 8)
    assert(kept_c > 10, 'without all the off-hue detail color stays colored: chroma ' .. kept_c)
    assert(flat_c < 1.5, 'with all it goes grey: chroma ' .. flat_c)
    local L_before = Colour.srgb_to_lab(0.55, 0.22, 0.30)
    local L_after = Colour.srgb_to_lab(flat[9], flat[10], flat[11])
    assert(math.abs(L_after - L_before) < 25, 'it keeps about its tone')
    -- a black pad with a brown strap (wear color, far from the black: kept without all) toward the SEAF blue
    local pad = test_row()
    pad[1], pad[2], pad[3] = 0.06, 0.06, 0.06
    pad[25], pad[26], pad[27] = 0.40, 0.26, 0.15
    transfer.fit(pad, 35, -0.5, -14, nil, nil, true)
    local strap_h, strap_c = hue_of(pad, 24)
    assert(strap_c > 2 and gap(strap_h, math.deg(math.atan2(-14, -0.5)) % 360) < 3,
           string.format('the strap takes the blue hue: %.1f degrees, chroma %.1f', strap_h, strap_c))
    -- a muted color (chroma about 10, under the goal's 14) keeps its own chroma: the goal's hue, not its strength
    local muted = test_row()
    muted[1], muted[2], muted[3] = 0.06, 0.06, 0.06
    muted[25], muted[26], muted[27] = 0.36, 0.31, 0.27
    local _, own_c = hue_of(muted, 24)
    transfer.fit(muted, 35, -0.5, -14, nil, nil, true)
    local _, muted_c = hue_of(muted, 24)
    assert(own_c > 8 and own_c < 13 and math.abs(muted_c - own_c) < 1.5,
           string.format('a muted color keeps its chroma: %.1f, now %.1f', own_c, muted_c))
    -- an olive plate with a brown wear color in its hue family (a rigid turn sends it to magenta) toward the blue
    local function olive()
        local c = test_row()
        c[1], c[2], c[3] = 0.33, 0.36, 0.20
        c[25], c[26], c[27] = 0.42, 0.33, 0.20
        return c
    end
    local turned, hued = olive(), olive()
    transfer.fit(turned, 35, -0.5, -14)
    transfer.fit(hued, 35, -0.5, -14, nil, nil, true)
    local goal_h = math.deg(math.atan2(-14, -0.5)) % 360
    local turned_h = hue_of(turned, 24)
    local hued_h = hue_of(hued, 24)
    assert(gap(turned_h, goal_h) > 15, string.format('without all the wear turns rigidly: %.1f degrees off', gap(turned_h, goal_h)))
    assert(gap(hued_h, goal_h) < 3, string.format('with all it takes the blue hue: %.1f degrees off', gap(hued_h, goal_h)))
end)

check('a flat role color fitted without a response sets a cloth row\'s sheen (column 12) to the goal\'s hue at its own '
      .. 'lightness: the DS-191 Scorpion\'s brown vest sheen read brown on SEAF black gear (round 8 renders 2026-10-09); '
      .. 'a fit through a response, a hard row, or no flat color leave the sheen alone; flat camo keeps half its '
      .. 'contrast (the SA-12 Twigsnapper\'s near-white stripes)', function()
    local transfer = Transfer.new(Colour, flat_model())
    local function cloth()
        local c = test_row()
        c[1], c[2], c[3], c[4] = 0.18, 0.11, 0.02, 1 -- the Scorpion's vest: a dark brown cloth (mode 1)
        c[49], c[50], c[51], c[52] = 0.148, 0.098, 0.062, 0.76 -- its brown sheen
        return c
    end
    local function sheen_chroma(c)
        local _, a, b = Colour.srgb_to_lab(c[49], c[50], c[51])
        return math.sqrt(a * a + b * b)
    end
    local before = sheen_chroma(cloth())
    local flat = cloth()
    transfer.fit(flat, 20, 0, 0, nil, nil, true)
    assert(before > 5 and sheen_chroma(flat) < 1, 'the sheen goes neutral: chroma ' .. sheen_chroma(flat))
    local L0 = Colour.srgb_to_lab(0.148, 0.098, 0.062)
    assert(math.abs(Colour.srgb_to_lab(flat[49], flat[50], flat[51]) - L0) < 0.5 and flat[52] == 0.76,
           'at its own lightness, its strength kept')
    local cal = {1, 1, 1, 0, 0, 0}
    for _, case in ipairs({{nil, false, 'no flat color'}, {cal, true, 'through a response'}}) do
        local c = cloth()
        transfer.fit(c, 20, 0, 0, case[1], nil, case[2])
        assert(c[49] == 0.148 and c[50] == 0.098 and c[51] == 0.062, case[3] .. ': the sheen stays')
    end
    local plate = cloth()
    plate[4] = 0 -- mode 0: column 12 is no sheen there
    transfer.fit(plate, 20, 0, 0, nil, nil, true)
    assert(plate[49] == 0.148 and plate[50] == 0.098 and plate[51] == 0.062, 'a hard row\'s column 12 stays')
    -- through apply: the sheen is written into the LUT with a flat color only
    local values = ffi.new('float[?]', 23 * 4)
    local c = cloth()
    for k = 1, 92 do values[k - 1] = c[k] end
    transfer.apply(values, 23, 0, {L = 20, a = 0, b = 0, all = true})
    local _, sa, sb = Colour.srgb_to_lab(values[48], values[49], values[50])
    assert(math.sqrt(sa * sa + sb * sb) < 1, 'apply writes the neutral sheen')
    -- flat camo: a quarter of the lightness offsets of the camo colors and of the base between them, all in the
    -- target's color (the SA-12 Twigsnapper's light grey base stayed white splashes, round 9 review)
    local function flat_camo(all)
        local r = test_row()
        r[1], r[2], r[3] = 0.77, 0.77, 0.77 -- a light grey base under an olive camo
        r[85], r[86], r[87], r[88] = 1, 0, 1, 2
        local camo = {{0.10, 0.14, 0.08}, {0.85, 0.88, 0.80}, {0.30, 0.38, 0.20}, {0.20, 0.30, 0.12}}
        for k, rgb in ipairs(camo) do
            local o = (15 + k) * 4
            r[o + 1], r[o + 2], r[o + 3] = rgb[1], rgb[2], rgb[3]
        end
        transfer.fit(r, 35, -0.5, -14, nil, nil, all)
        local lo, hi = 100, 0
        for column = 16, 19 do
            local L = Colour.srgb_to_lab(r[column * 4 + 1], r[column * 4 + 2], r[column * 4 + 3])
            lo, hi = math.min(lo, L), math.max(hi, L)
        end
        return hi - lo, r
    end
    local full, kept = flat_camo(false)
    local flat_spread, flat_row = flat_camo(true)
    assert(flat_spread < 0.4 * full and flat_spread > 0.1 * full,
           string.format('camo spread %.1f, flat %.1f', full, flat_spread))
    local _, ka, kb = Colour.srgb_to_lab(kept[1], kept[2], kept[3])
    local fL, fa, fb = Colour.srgb_to_lab(flat_row[1], flat_row[2], flat_row[3])
    local base_hue = math.deg(math.atan2(fb, fa)) % 360
    assert(math.sqrt(ka * ka + kb * kb) < 8, 'without all the camo base keeps no blue of its own')
    assert(math.sqrt(fa * fa + fb * fb) > 8 and base_hue > 250 and base_hue < 290 and fL < 60,
           string.format('with all the base takes the blue: L %.1f a %.1f b %.1f', fL, fa, fb))
end)

-- An item from {key, area, L, a, b[, bare metal[, undergarment fraction]]} rows (no camo; paint unless the 6th is
-- true) and patterns {{pattern, area, r, g, b}} (texel 0 in sRGB).
local function item(rows, armor, patterns)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {key = r[1], area = r[2], under = r[2] * (r[7] or 0), L = r[3], a = r[4], b = r[5],
                  metal = r[6] == true, camo = false, mode = r[8] or 0, full = r[6] == true}
    end
    return Matcher.item(out, armor, patterns)
end

check('a cape of one dark color and vivid ones shows each of 15% or more on a muted part, never a smaller one; a muted '
      .. 'color of 10% keeps the vivid guard (gallery 2026-10-11: the FS-37 Ravager one dark grey under the black cape '
      .. '0beb97bc with its 21% red)', function()
    local armor = {{'aaaaaaaaaaaaaaaa:0', 45, 31.9, 2, 7}, {'aaaaaaaaaaaaaaaa:1', 30, 24, 0, 0},
                   {'aaaaaaaaaaaaaaaa:2', 15, 35.7, -5, 7}, {'aaaaaaaaaaaaaaaa:3', 10, 33, 1, 4}}
    local function reds(cape_rows, not_cape, target)
        local s = item(cape_rows, false)
        s.cape_source = not not_cape
        local n = 0
        for _, m in pairs(Matcher.plan(item(target or armor, true), s)) do
            if m.source == 'bbbbbbbbbbbbbbbb:1' then n = n + 1 end
        end
        return n
    end
    local red = {33.9, 33, 25}
    local n = reds({{'bbbbbbbbbbbbbbbb:0', 79, 22.4, 0, 0}, {'bbbbbbbbbbbbbbbb:1', 21, red[1], red[2], red[3]}})
    assert(n >= 1, 'black 79%, red 21%: a muted part takes the red')
    n = reds({{'bbbbbbbbbbbbbbbb:0', 86, 22.4, 0, 0}, {'bbbbbbbbbbbbbbbb:1', 14, red[1], red[2], red[3]}})
    assert(n == 0, 'black 86%, red 14%: the red a minority, guarded (' .. n .. ' parts)')
    n = reds({{'bbbbbbbbbbbbbbbb:0', 60, 22.4, 0, 0}, {'bbbbbbbbbbbbbbbb:1', 25, red[1], red[2], red[3]},
              {'bbbbbbbbbbbbbbbb:2', 15, 50, 0, 2}})
    assert(n == 0, 'black 60%, red 25%, grey 15%: the grey gives the second color, the red guarded (' .. n .. ' parts)')
    -- a vivid second main color (25% or more, 20 L lighter) is no minority from any source (the Thundering Hooves'
    -- gold, user 2026-10-10)
    local plated = {{'aaaaaaaaaaaaaaaa:0', 50, 30, 2, 7}, {'aaaaaaaaaaaaaaaa:1', 25, 24, 0, 0},
                    {'aaaaaaaaaaaaaaaa:2', 25, 65, 0, 2}}
    n = reds({{'bbbbbbbbbbbbbbbb:0', 55, 22.4, 0, 0}, {'bbbbbbbbbbbbbbbb:1', 30, 71, 5, 60},
              {'bbbbbbbbbbbbbbbb:2', 15, 50, 0, 2}}, true, plated)
    assert(n >= 1, 'black 55%, gold 30% (L 71), grey 15%, not a cape: the light grey plates take the gold')
    -- from a helmet or armor a vivid color of 10% or more is no minority, as dark as the main or not: a red of 30%
    -- (L 34) on black takes a muted part (the user's version comparisons 2026-10-15: the FS-05 Marksman's red never
    -- reached the FS-37 Ravager, "the red failed to transfer"); one of 8% stays guarded
    n = reds({{'bbbbbbbbbbbbbbbb:0', 70, 22.4, 0, 0}, {'bbbbbbbbbbbbbbbb:1', 30, red[1], red[2], red[3]}}, true)
    assert(n >= 1, 'black 70%, red 30% (L 34), not a cape: a muted part takes the red (' .. n .. ' parts)')
    n = reds({{'bbbbbbbbbbbbbbbb:0', 92, 22.4, 0, 0}, {'bbbbbbbbbbbbbbbb:1', 8, red[1], red[2], red[3]}}, true)
    assert(n == 0, 'black 92%, red 8%, not a cape: the red a minority, guarded (' .. n .. ' parts)')
    -- but not one bigger than the identity, which the identity passed over (the PH-9 Predator's red beret, 42% over its
    -- olive's 29%: the I-44 Salamander turned red on 43% of its paint, user 2026-10-15 "places red on almost everything
    -- as a dominant color")
    n = reds({{'bbbbbbbbbbbbbbbb:0', 29, 23, -3, 6}, {'bbbbbbbbbbbbbbbb:1', 42, red[1], red[2], red[3]},
              {'bbbbbbbbbbbbbbbb:2', 29, 18, 1, 1}}, true)
    assert(n == 0, 'olive 29% (the identity), red 42%, black 29%, not a cape: the red guarded (' .. n .. ' parts)')
    -- nor does a colored part that is not vivid itself take such a color (brown leather, model chroma 27, 16%: the
    -- CPG-48 SAPPER's gloves and boots took the PH-9 Predator's beret red, user 2026-10-15 "the boots and gloves aren't
    -- even accented"); its 4% yellow accent still takes the red
    local sapper = {{'aaaaaaaaaaaaaaaa:0', 50, 31, -1, 20}, {'aaaaaaaaaaaaaaaa:1', 30, 33, 2, 3},
                    {'aaaaaaaaaaaaaaaa:2', 16, 29, 9, 26}, {'aaaaaaaaaaaaaaaa:3', 4, 49, -7, 45}}
    local beret = item({{'bbbbbbbbbbbbbbbb:0', 29, 23, -3, 6}, {'bbbbbbbbbbbbbbbb:1', 42, red[1], red[2], red[3]},
                        {'bbbbbbbbbbbbbbbb:2', 29, 18, 1, 1}}, false)
    local leather = Matcher.plan(item(sapper, true), beret)
    assert(leather['aaaaaaaaaaaaaaaa:2'] and leather['aaaaaaaaaaaaaaaa:2'].source ~= 'bbbbbbbbbbbbbbbb:1',
           'brown leather 16% (chroma 27): no beret red')
    assert(leather['aaaaaaaaaaaaaaaa:3'] and leather['aaaaaaaaaaaaaaaa:3'].source == 'bbbbbbbbbbbbbbbb:1',
           'the yellow accent takes the red')
    -- and makes its identity the dark one for the anchor: a red identity (L 36, not dark) under a lighter gold landed
    -- on the light plates and the dark main took the red too (the Thundering Hooves on the SR-64 Cinderblock, user
    -- 2026-10-10; a cape now goes by its outside, so a helmet or armor source keeps the case)
    local s = item({{'bbbbbbbbbbbbbbbb:0', 55, 35.5, 46.8, 28.3}, {'bbbbbbbbbbbbbbbb:1', 40, 70.5, 8.0, 46.4},
                    {'bbbbbbbbbbbbbbbb:2', 5, 25.5, 21.2, 9.6}}, false)
    local plan = Matcher.plan(item({{'aaaaaaaaaaaaaaaa:0', 72, 21, 0, 1}, {'aaaaaaaaaaaaaaaa:1', 19, 43, 0, 1},
                                    {'aaaaaaaaaaaaaaaa:2', 9, 50, 1, 4}}, true), s)
    assert(plan['aaaaaaaaaaaaaaaa:0'].source == 'bbbbbbbbbbbbbbbb:0' and plan['aaaaaaaaaaaaaaaa:1'].source
           == 'bbbbbbbbbbbbbbbb:1', string.format('the dark main the red, the light plates the gold (%s, %s)',
           plan['aaaaaaaaaaaaaaaa:0'].source, plan['aaaaaaaaaaaaaaaa:1'].source))
end)

check('a colored band paired with a neutral black takes the source accent\'s color (user 2026-10-09: the '
      .. 'IX-VOIDWALKER\'s navy band "turns pitch black on multiple armors"; 2026-10-10: its darker shade read orange '
      .. 'on the B-01 Tactical, "should be yellow"); a source with no colored paint gives its light strips\' color (a '
      .. 'B-01 Tactical helmet\'s red stripes went grey with the KDM-763 Pacesetter\'s yellow lights); without either '
      .. 'it stays', function()
    local helmet = {{'aaaaaaaaaaaaaaaa:0', 65, 66.7, 0, 7.3}, {'aaaaaaaaaaaaaaaa:1', 26, 32.8, -1.6, -10.1},
                    {'aaaaaaaaaaaaaaaa:3', 9, 20.3, 0, 0}}
    local band = 'aaaaaaaaaaaaaaaa:1'
    -- black with a vivid red the band may not take itself (vivid_minor_guard): black is its pair
    local dress = {{'bbbbbbbbbbbbbbbb:0', 85, 25.3, 0.5, 0.5}, {'bbbbbbbbbbbbbbbb:2', 15, 33.9, 33, 25}}
    local plain = {{'cccccccccccccccc:0', 80, 25.3, 0.5, 0.5}, {'cccccccccccccccc:1', 12, 69.5, 0, 0.5},
                   {'cccccccccccccccc:2', 8, 45, 1, 3}}
    local t = item(helmet, false)
    local m = Matcher.plan(t, item(dress, true))[band]
    assert(math.abs(m.L - 33.9) < 0.01 and math.abs(m.a - 33) < 0.01 and math.abs(m.b - 25) < 0.01,
           string.format('the accent\'s red: L %.1f a %.1f b %.1f', m.L, m.a, m.b))
    -- black paint with yellow light strips (mode 3: no paint, no accent)
    local lit = {{'dddddddddddddddd:0', 90, 25.3, 0.5, 0.5}, {'dddddddddddddddd:1', 5, 47, -8, 45, false, 0, 3}}
    local y = Matcher.plan(t, item(lit, true))[band]
    assert(math.abs(y.L - 47) < 0.01 and math.abs(y.b - 45) < 0.01,
           string.format('the light strips\' yellow: L %.1f a %.1f b %.1f', y.L, y.a, y.b))
    local kept = Matcher.plan(t, item(plain, true))[band]
    assert(kept.source:find('^cccc') and math.sqrt(kept.a ^ 2 + kept.b ^ 2) < 5,
           string.format('no colored source part: as paired (%s a %.1f b %.1f)', kept.source, kept.a, kept.b))
    -- the item's largest part is its main, never a band (a red main of 45% turned yellow: "inverted"); a light stripe
    -- the pairing turned black is one (its white stripe, 18%, takes the yellow)
    local red = {{'eeeeeeeeeeeeeeee:0', 45, 22, 32, 18}, {'eeeeeeeeeeeeeeee:1', 37, 22, 0, 0},
                 {'eeeeeeeeeeeeeeee:2', 18, 68, 0, 7}}
    local striped = Matcher.plan(item(red, false), item(lit, true))
    local main, stripe = striped['eeeeeeeeeeeeeeee:0'], striped['eeeeeeeeeeeeeeee:2']
    assert(math.sqrt(main.a ^ 2 + main.b ^ 2) < 5, string.format('the red main as paired: a %.1f b %.1f', main.a, main.b))
    assert(math.abs(stripe.L - 47) < 0.01 and math.abs(stripe.b - 45) < 0.01,
           string.format('the white stripe the yellow: L %.1f a %.1f b %.1f', stripe.L, stripe.a, stripe.b))
    -- a hard paint part of the stripe's color (4%, a group of its own) takes it too; a bare-metal part of that color is
    -- a metal finish and keeps its pairing (the B-01 Tactical helmet's silver jaw badges, gallery round 22), as does a
    -- part of another color; the helmet's own white dome stripes are a pattern (the pattern plan's band coat)
    red[4] = {'eeeeeeeeeeeeeeee:3', 4, 70, -1, 0, true}
    red[5] = {'eeeeeeeeeeeeeeee:4', 4, 40, 0, 0}
    red[6] = {'eeeeeeeeeeeeeeee:5', 4, 69, 0, -1} -- dE 7 from the stripe: a group of its own, under KEEP_DE
    local more = Matcher.plan(item(red, false), item(lit, true))
    local metal, grey, painted = more['eeeeeeeeeeeeeeee:3'], more['eeeeeeeeeeeeeeee:4'], more['eeeeeeeeeeeeeeee:5']
    assert(painted and painted.band and math.abs(painted.b - 45) < 0.01, 'a painted part of the stripe\'s color the yellow')
    assert(metal and not metal.band and math.abs(metal.b) < 5, 'a bare-metal part of that color as paired')
    assert(grey and not grey.band and math.abs(grey.b) < 5, 'a grey part of another color as paired')
    red[4], red[5], red[6] = nil, nil, nil
    -- a muted part (model chroma under 9) is no band
    helmet[2][4], helmet[2][5] = -1, -5
    local muted = Matcher.plan(item(helmet, false), item(dress, true))[band]
    assert(muted.source:find('^bbbb') and math.sqrt(muted.a ^ 2 + muted.b ^ 2) < 1, string.format(
           'a muted part as paired (%s a %.1f b %.1f)', muted.source, muted.a, muted.b))
end)

-- Reddit report 2026-10-14: the O-44 Bonded Pilot's red-brown plates (a band, 25% of it) took the RS-100 Sanctioner's
-- 2.8% gold and the armor read light gold; v1.3 made them its black. An armor's band takes a source color covering 10%
-- of the source (the user's floor for a secondary) and no light; a helmet's keeps the agreed rule.
check('an armor\'s band takes a source color covering 10% of the source and never a light; a helmet\'s band takes '
      .. 'a smaller one as agreed', function()
    local rows = {{'aaaaaaaaaaaaaaaa:0', 65, 66.7, 0, 7.3}, {'aaaaaaaaaaaaaaaa:1', 26, 32.8, -1.6, -10.1},
                  {'aaaaaaaaaaaaaaaa:3', 9, 20.3, 0, 0}}
    local band = 'aaaaaaaaaaaaaaaa:1'
    local function source(red_share, lit)
        local rows_s = {{'bbbbbbbbbbbbbbbb:0', 100 - red_share, 25.3, 0.5, 0.5}}
        rows_s[2] = lit and {'bbbbbbbbbbbbbbbb:1', red_share, 47, -8, 45, false, 0, 3}
            or {'bbbbbbbbbbbbbbbb:2', red_share, 33.9, 33, 25}
        return item(rows_s, false) -- a helmet as the source
    end
    local function colored(m) return m and m.band and math.sqrt(m.a ^ 2 + m.b ^ 2) > 20 end
    local armor, helmet = item(rows, true), item(rows, false)
    assert(not colored(Matcher.plan(armor, source(3))[band]), 'an armor\'s band and a 3% red: as paired (black)')
    assert(colored(Matcher.plan(armor, source(15))[band]), 'an armor\'s band and a 15% red: the red')
    assert(not colored(Matcher.plan(armor, source(5, true))[band]), 'an armor\'s band and a light: as paired')
    assert(colored(Matcher.plan(helmet, source(3))[band]), 'a helmet\'s band and a 3% red: the red (agreed)')
    assert(colored(Matcher.plan(helmet, source(5, true))[band]), 'a helmet\'s band and a light: the light (agreed)')
end)

-- SEAF material roles on small synthetic armors: {key ('lut:row'), area, L, mode (0 hard, 1 soft), undergarment
-- fraction} rows, neutral colors; the scheme's three rows as their own source item.
local Schemes = require('schemes')
local function role_item(rows)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {key = r[1], lut = r[1]:match('^(%x+):'), row = tonumber(r[1]:match(':(%d+)$')), area = r[2],
                  under = r[2] * r[5], L = r[3], a = 0, b = 0, metal = false, camo = false, mode = r[4], full = false}
    end
    return Matcher.item(out, true)
end
local function seaf_roles(rows)
    local source = Matcher.item({
        {key = 'eeee:2', lut = 'eeee', row = 2, area = 0.6, under = 0, L = 35, a = -0.5, b = -14, mode = 0},
        {key = 'eeee:1', lut = 'eeee', row = 1, area = 0.25, under = 0, L = 40, a = 0, b = 0, mode = 1},
        {key = 'eeee:3', lut = 'eeee', row = 3, area = 0.15, under = 0.15, L = 20, a = 0, b = 0, mode = 1}}, true)
    local plan = Schemes.role_plan(Matcher, role_item(rows), source, {'eeee:2', 'eeee:1', 'eeee:3'})
    local names = {['eeee:2'] = 'blue', ['eeee:1'] = 'uniform', ['eeee:3'] = 'gear'}
    local out = {}
    for key, m in pairs(plan) do out[key] = names[m.source] end
    return out
end

check('SEAF roles: an armor with its own light clothing keeps its dark clothing black, even a LUT\'s only dark row '
      .. '(gloves of their own); an all-black armor takes the uniform on a LUT\'s clearly largest dark cloth only, not '
      .. 'on near-equal rows (the SA-12 Twigsnapper\'s trousers and boots; independent image review 2026-10-09)',
      function()
    local with_shirt = seaf_roles({
        {'aaaa:0', 30, 60, 1, 1},   -- a light shirt (undergarment)
        {'bbbb:0', 8, 15, 1, 1},    -- black gloves, alone in their LUT
        {'dddd:0', 22, 15, 1, 1},   -- black trousers, alone in their LUT
        {'cccc:0', 40, 50, 0, 0}})  -- light plates
    assert(with_shirt['aaaa:0'] == 'uniform' and with_shirt['cccc:0'] == 'blue', 'shirt grey, plates blue')
    assert(with_shirt['bbbb:0'] == 'gear' and with_shirt['dddd:0'] == 'gear', 'gloves and trousers stay black')
    local all_black = seaf_roles({
        {'aaaa:0', 20, 15, 1, 1}, {'aaaa:1', 5, 15, 1, 1},     -- torso: jacket clearly largest, then gloves
        {'dddd:0', 10, 15, 1, 1}, {'dddd:1', 9.5, 15, 1, 1},   -- legs: near-equal trousers and boots
        {'cccc:0', 40, 15, 0, 0}})                               -- black plates
    assert(all_black['aaaa:0'] == 'uniform' and all_black['aaaa:1'] == 'gear', 'jacket grey, gloves black')
    assert(all_black['dddd:0'] == 'gear' and all_black['dddd:1'] == 'gear', 'near-equal trousers and boots stay black')
    assert(all_black['cccc:0'] == 'blue', 'its black plates blue')
end)

local Capes = require('capes')

check('Match Cape: a dark muted part (gloves, boots) never takes a light cape color it does not match; left with none '
      .. 'it takes the cape\'s darkest; light parts and colored dark parts keep their choices (independent image '
      .. 'review 2026-10-09)', function()
    local t = {{mL = 17, ma = 0.3, mb = 13.8, share = 0.3}, {mL = 50, ma = 0, mb = 10, share = 0.3},
               {mL = 20, ma = 30, mb = 10, share = 0.3}}
    -- every color on the cape's outside (the lining guard keeps out), the largest not the darkest (its fallback differs)
    local outside = {{area = 1, outside = 1}}
    local s = {{L = 30, ma = 0, mb = 0, share = 0.2, rows = outside}, {L = 71, ma = 0, mb = 0, share = 0.3, rows = outside},
               {L = 32, ma = 0, mb = 0, share = 0.5, rows = outside}}
    local function fresh() return {{true, true, true}, {true, true, true}, {true, true, true}} end
    local keep = {{false, false, false}, {false, false, false}, {false, false, false}}
    local allowed = fresh()
    Capes.dark_parts_guard(allowed, t, s, keep, 20)
    assert(allowed[1][1] and not allowed[1][2] and allowed[1][3], 'the dark part loses the cream only')
    assert(allowed[2][2] and allowed[3][2], 'a light part and a colored dark part keep it')
    local only_light = {{false, true, false}, {true, true, true}, {true, true, true}}
    Capes.dark_parts_guard(only_light, t, s, keep, 20)
    assert(not only_light[1][2] and only_light[1][1] and not only_light[1][3], 'left with none: the darkest (L 30)')
    local matched = fresh()
    keep[1][2] = true
    Capes.dark_parts_guard(matched, t, s, keep, 20)
    assert(matched[1][2], 'a part that already matches the cream keeps it')
end)

check('Match Cape: a tinted cape color shown only on its lining (under Capes.LINING_OUTSIDE outside) paints no part '
      .. 'larger than an accent it does not match; left with none, the part takes the most outside color; a color the '
      .. 'outside shows too, or a grey lining, stays (independent review 2026-10-11, case 70: the EX-00 Prototype X\'s '
      .. 'grey dome took a taupe lining; the user chose "outside first"; a guarded grey lining made one yellow suit)',
      function()
    local t = {{mL = 44, ma = 0, mb = 0, share = 0.6}, {mL = 44, ma = 0, mb = 0, share = 0.05},
               {mL = 44, ma = 0, mb = 0, share = 0.3}}
    local s = {{L = 40, ma = 3.7, mb = 9.6, share = 0.33, rows = {{area = 1, outside = 0}}},   -- the lining alone, taupe
               {L = 21, ma = 0, mb = 0, share = 0.29, rows = {{area = 1, outside = 1}}},       -- outside
               {L = 36, ma = 0, mb = 12, share = 0.38,
                rows = {{area = 2, outside = 0}, {area = 1, outside = 1}}}}                     -- a third outside
    local function fresh() return {{true, true, true}, {true, true, true}, {true, true, true}} end
    local keep = {{false, false, false}, {false, false, false}, {false, false, false}}
    local allowed = fresh()
    Capes.dark_parts_guard(allowed, t, s, keep, 20)
    assert(not allowed[1][1] and allowed[1][2] and allowed[1][3], 'a large part loses the lining-only color only')
    assert(allowed[2][1], 'an accent-size part (5%) may take it')
    local only_lining = {{true, false, false}, fresh()[2], fresh()[3]}
    Capes.dark_parts_guard(only_lining, t, s, keep, 20)
    assert(not only_lining[1][1] and only_lining[1][2] and not only_lining[1][3],
           'left with none: the most outside color (29% all outside over 38% a third outside)')
    keep[3][1] = true
    local matched = fresh()
    Capes.dark_parts_guard(matched, t, s, keep, 20)
    assert(matched[3][1] and not matched[1][1], 'a part that already matches the lining color keeps it')
    s[1].ma, s[1].mb = 0.3, 1.0 -- a grey lining (the Light of Eternal Liberty's, chroma 1)
    keep[3][1] = false
    local grey = fresh()
    Capes.dark_parts_guard(grey, t, s, keep, 20)
    assert(grey[1][1], 'a grey lining stays a shade a large part may take')
end)

check('capes: BC3 blocks decode as Pillow decodes them (the parity reference), in both alpha modes', function()
    local out = ffi.new('uint8_t[64]')
    local function block(bytes) return ffi.new('uint8_t[16]', bytes) end
    Capes.bc3_block(block({255, 0, 0x92, 0x24, 0x49, 0x92, 0x24, 0x49, 0x00, 0xF8, 0x1F, 0x00, 0xAA, 0xAA, 0xAA, 0xAA}),
                    out)
    for t = 0, 15 do
        assert(out[t * 4] == 170 and out[t * 4 + 1] == 0 and out[t * 4 + 2] == 85 and out[t * 4 + 3] == 218, 'texel ' .. t)
    end
    Capes.bc3_block(block({10, 200, 0x88, 0xC6, 0xFA, 0x88, 0xC6, 0xFA, 0x1F, 0x00, 0xE0, 0x07, 0xE4, 0xE4, 0xE4, 0xE4}),
                    out)
    local want = {{0, 0, 255, 10}, {0, 255, 0, 200}, {0, 85, 170, 48}, {0, 170, 85, 86}, {0, 0, 255, 124},
                  {0, 255, 0, 162}, {0, 85, 170, 0}, {0, 170, 85, 255}}
    for t = 0, 15 do
        local w = want[t % 8 + 1]
        for c = 1, 4 do assert(out[t * 4 + c - 1] == w[c], string.format('texel %d channel %d', t, c)) end
    end
end)

check('capes: the outside takes the first of R, G, B set (rows 1-3; from byte 127, the shader\'s 0.496), else row 0; '
      .. 'the inside 1 for R, else 4; A cuts below 128', function()
    local g = Capes.GRID
    local cells = ffi.new('uint8_t[?]', g * g * 4)
    local function fill(r, gr, b, a)
        for i = 0, g * g - 1 do cells[i * 4], cells[i * 4 + 1], cells[i * 4 + 2], cells[i * 4 + 3] = r, gr, b, a end
    end
    fill(0, 0, 0, 255)
    local areas = Capes.areas(cells, 7)
    assert(areas[0] == 13 / 20 and areas[4] == 7 / 20 and not areas[1], 'plain: outside row 0, inside row 4')
    fill(0, 0, 255, 255)
    areas = Capes.areas(cells, 7)
    assert(areas[3] == 13 / 20 and areas[4] == 7 / 20, 'B: outside row 3, the inside keeps row 4')
    fill(0, 255, 0, 255)
    areas = Capes.areas(cells, 7)
    assert(areas[2] == 13 / 20 and areas[4] == 7 / 20, 'G: outside row 2')
    fill(255, 0, 0, 255)
    assert(Capes.areas(cells, 7)[1] == 1, 'R: row 1 on both sides')
    fill(255, 255, 255, 255)
    assert(Capes.areas(cells, 7)[1] == 1, 'outside R before G before B (the shader\'s loop); inside R')
    fill(0, 255, 255, 255)
    areas = Capes.areas(cells, 7)
    assert(areas[2] == 13 / 20 and areas[4] == 7 / 20, 'G before B')
    fill(127, 0, 0, 255)
    assert(Capes.areas(cells, 7)[1] == 1, 'byte 127 is set (0.498 >= 0.496)')
    fill(126, 0, 0, 255)
    assert(Capes.areas(cells, 7)[0] == 13 / 20, 'byte 126 is not')
    fill(0, 0, 0, 255)
    areas = Capes.areas(cells, 3)
    assert(areas[0] == 1 and not areas[4], 'a LUT of 3 rows has no inside row')
    fill(0, 0, 0, 127)
    assert(next((Capes.areas(cells, 7))) == nil, 'A below half: nothing shows')
    fill(0, 0, 0, 255)
    cells[0], cells[2] = 255, 255 -- the top-left cell lies outside the outline
    assert(Capes.areas(cells, 7)[0] == 13 / 20, 'outside the outline nothing counts')
    local outline, inside = Capes.outline(), 0
    for i = 0, g * g - 1 do inside = inside + outline[i] end
    assert(inside == 8583, 'the outline the 17 capes share: ' .. inside .. ' of ' .. g * g .. ' cells')
end)

check('capes: cells inside the outline sample the smallest mip of at least the grid, nearest texel (RGBA8, RGBA16F); '
      .. 'cells outside it are not written', function()
    local Texture = require('texture')
    local function info(format, w, h, mips, per)
        local i = {format = format, width = w, height = h, mips = mips, mip_offsets = {}, layer_bytes = 0, layers = 1}
        for m = 0, mips - 1 do
            i.mip_offsets[m] = i.layer_bytes
            i.layer_bytes = i.layer_bytes + math.max(1, math.floor(w / 2 ^ m)) * math.max(1, math.floor(h / 2 ^ m)) * per
        end
        return i
    end
    local big = info(Texture.FORMAT_RGBA8, 256, 256, 9, 4)
    local function pixels(at, size, out, offset) -- mip 1 (128 x 128) holds x, y, 7, 255; any other byte 99
        for k = 0, size - 1 do
            local o = at + k - big.mip_offsets[1]
            local texel = math.floor(o / 4)
            local v = 99
            if o >= 0 and o < 128 * 128 * 4 then v = ({texel % 128, math.floor(texel / 128), 7, 255})[o % 4 + 1] end
            out[offset + k] = v
        end
    end
    local g, outline = Capes.GRID, Capes.outline()
    local cells = ffi.new('uint8_t[?]', g * g * 4)
    ffi.fill(cells, g * g * 4, 0xEE)
    local pauses = 0
    Capes.cells(Texture, pixels, big, Slim.grower(1024), cells, function() pauses = pauses + 1 end)
    assert(pauses == g, 'a pause point after every grid row')
    local first, last
    for i = 0, g * g - 1 do
        if outline[i] == 1 then
            first, last = first or i, i
            local x, y = i % g, math.floor(i / g)
            assert(cells[i * 4] == x and cells[i * 4 + 1] == y and cells[i * 4 + 2] == 7 and cells[i * 4 + 3] == 255,
                   'mip 1, nearest texel ' .. x .. ',' .. y)
        else
            for c = 0, 3 do assert(cells[i * 4 + c] == 0xEE, 'a cell outside the outline is not written') end
        end
    end
    assert(first and last > first, 'cells inside the outline')
    local small = info(Texture.FORMAT_RGBA16F, 4, 4, 3, 8) -- the shared default: 4 x 4 halves, A 1
    local one = {0x00, 0x3C}
    Capes.cells(Texture, function(at, size, out, offset)
        for k = 0, size - 1 do out[offset + k] = (at + k) % 8 >= 6 and one[(at + k) % 2 + 1] or 0 end
    end, small, Slim.grower(64), cells)
    for i = 0, g * g - 1 do
        if outline[i] == 1 then
            assert(cells[i * 4] == 0 and cells[i * 4 + 3] == 255, 'RGBA16F 0 and 1 to bytes 0 and 255')
        end
    end
    -- a mod's RGBA32F texture: the same values as 32-bit floats (R 0.25, G 2 clamps to 1, B NaN to 0, A -1 to 0)
    local floats = info(Texture.FORMAT_RGBA32F, 4, 4, 3, 16)
    local texel = ffi.new('float[4]', {0.25, 2, 0, -1})
    local texel_bytes = ffi.cast('uint8_t *', texel)
    texel_bytes[8], texel_bytes[9], texel_bytes[10], texel_bytes[11] = 0x01, 0x00, 0xC0, 0x7F -- B: a NaN
    Capes.cells(Texture, function(at, size, out, offset)
        for k = 0, size - 1 do out[offset + k] = texel_bytes[(at + k) % 16] end
    end, floats, Slim.grower(64), cells)
    for i = 0, g * g - 1 do
        if outline[i] == 1 then
            assert(cells[i * 4] == 64 and cells[i * 4 + 1] == 255 and cells[i * 4 + 2] == 0 and cells[i * 4 + 3] == 0,
                   'RGBA32F clamped and rounded to bytes')
        end
    end
end)

check('an uncompressed (RGBA8) decal sheet\'s texels read one by one (an emblem\'s colors) are its own bytes, also '
      .. 'while Capes.cells is paused at a pause point (its RGBA8 cells are copied as words through views it sets for '
      .. 'its loop; independent review 2026-10-11: the sheet read went through them while unset)', function()
    local Texture = require('texture')
    local w, h = 8, 4
    local sheet_info = {format = Texture.FORMAT_RGBA8, width = w, height = h, mips = 1, mip_offsets = {[0] = 0},
                        layer_bytes = w * h * 4, layers = 1}
    local function sheet_pixels(at, size, out, offset)
        for k = 0, size - 1 do out[offset + k] = (at + k) % 251 end
    end
    local raw, cell, codec = Capes.read_mip(Texture, sheet_pixels, sheet_info, 0, Slim.grower(256))
    local sheet = {raw = raw, cell = cell, codec = codec, wide = w}
    local function check_sheet(when)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local texel, o = Capes.sheet_texel(sheet, x, y), (y * w + x) * 4
                for c = 0, 3 do
                    assert(texel[c] == (o + c) % 251, string.format('%s: texel %d,%d channel %d', when, x, y, c))
                end
            end
        end
    end
    check_sheet('before any cells')
    local g = Capes.GRID
    local cells = ffi.new('uint8_t[?]', g * g * 4)
    local big = {format = Texture.FORMAT_RGBA8, width = 64, height = 64, mips = 1, mip_offsets = {[0] = 0},
                 layer_bytes = 64 * 64 * 4, layers = 1}
    local paused = 0
    Capes.cells(Texture, function(at, size, out, offset)
        for k = 0, size - 1 do out[offset + k] = 200 end
    end, big, Slim.grower(1024), cells, function()
        paused = paused + 1
        if paused == 3 then check_sheet('at a pause point of Capes.cells') end
    end)
    check_sheet('after Capes.cells')
    for i = 0, g * g - 1 do
        if Capes.outline()[i] == 1 then assert(cells[i * 4] == 200, 'the cells as words') end
    end
end)

-- The Lua stack counts in collectgarbage('count'): a full collection halves a mostly unused stack
-- (lj_state_shrinkstack) and the next deep call doubles it again (1016 bytes in the game's lua51.dll once the matcher
-- grew, 2026-10-07; tests/test_idle_alloc.lua). Recursing this deep just before the GC stops keeps it grown.
local STACK_DEPTH = 200
local function grow_stack(depth)
    if depth == 0 then return 0 end
    return grow_stack(depth - 1) + 1 -- not a tail call: one stack frame per level
end

check('capes: the BC3 and BC7 block decoders read at an offset as at the start and allocate nothing per block',
      function()
    local Texture = require('texture')
    local bc3 = {255, 0, 0x92, 0x24, 0x49, 0x92, 0x24, 0x49, 0x00, 0xF8, 0x1F, 0x00, 0xAA, 0xAA, 0xAA, 0xAA}
    local bc7 = {0x40, 0x9B, 0x27, 0x51, 0xE3, 0x0C, 0x7F, 0x18, 0xC4, 0x66, 0x2D, 0x91, 0x5A, 0xB7, 0x03, 0xEE}
    for _, case in ipairs({{Capes.bc3_block, bc3, 'BC3'}, {Texture.bc7_block, bc7, 'BC7'}}) do
        local decode, bytes, name = case[1], case[2], case[3]
        local alone, inside = ffi.new('uint8_t[16]', bytes), ffi.new('uint8_t[48]')
        for k = 1, 16 do inside[31 + k] = bytes[k] end
        local a, b = ffi.new('uint8_t[64]'), ffi.new('uint8_t[64]')
        decode(alone, a)
        decode(inside, b, 32)
        for k = 0, 63 do assert(a[k] == b[k], name .. ' at an offset: byte ' .. k) end
        for _ = 1, 200 do decode(inside, b, 32) end -- warm up: traces the JIT compiles count toward the heap too
        collectgarbage('collect') -- lint-ok: R4 test process only
        assert(grow_stack(STACK_DEPTH) == STACK_DEPTH)
        collectgarbage('stop') -- lint-ok: R4 test process only
        local before = collectgarbage('count') -- lint-ok: R4 test process only
        for _ = 1, 200 do decode(inside, b, 32) end
        local grown = (collectgarbage('count') - before) * 1024 -- lint-ok: R4 test process only
        collectgarbage('restart') -- lint-ok: R4 test process only
        assert(grown == 0, string.format('%s: 200 blocks allocated %.0f bytes', name, grown))
    end
end)

check('capes: BC4 blocks (gradients) decode with BC3\'s alpha arithmetic (research/capes.py bc4_decode) into R, at an '
      .. 'offset', function()
    local out = ffi.new('uint8_t[64]')
    local blocks = ffi.new('uint8_t[24]', {0, 0, 0, 0, 0, 0, 0, 0, 200, 10, 0x88, 0xC6, 0xFA, 0x88, 0xC6, 0xFA,
                                           10, 200, 0x88, 0xC6, 0xFA, 0x88, 0xC6, 0xFA})
    Capes.bc4_block(blocks, out, 8) -- texel n takes index n % 8
    local eight = {200, 10, 172, 145, 118, 91, 64, 37}
    for t = 0, 15 do
        assert(out[t * 4] == eight[t % 8 + 1] and out[t * 4 + 1] == 0 and out[t * 4 + 2] == 0 and out[t * 4 + 3] == 255,
               'eight values (a0 > a1): texel ' .. t)
    end
    Capes.bc4_block(blocks, out, 16)
    local six = {10, 200, 48, 86, 124, 162, 0, 255}
    for t = 0, 15 do assert(out[t * 4] == six[t % 8 + 1], 'six values, then 0 and 255: texel ' .. t) end
end)

check('capes: a row\'s tint covers t = |w| x saturate(c6.w x (g\' - c6.z)) of its cells (w < 0: g\' = 1 - g), in '
      .. 'TINT_STEPS; rows past the cape LUT\'s height and a missing gradient have none; the base keeps the rest',
      function()
    local g, S = Capes.GRID, Capes.TINT_STEPS
    local cells, grad = ffi.new('uint8_t[?]', g * g * 4), ffi.new('uint8_t[?]', g * g * 4)
    for i = 0, g * g - 1 do cells[i * 4 + 3] = 255 end -- plain: outside row 0, inside row 4
    local values = ffi.new('float[64]') -- a 16 x 1 cape LUT: row 0 only
    local tint = {values = values, width = 16, height = 1}
    local function areas(w, z6, w6, level)
        values[15], values[26], values[27] = w, z6, w6 -- column 3 w, column 6 z and w
        for i = 0, g * g - 1 do grad[i * 4] = level end
        return Capes.areas(cells, 7, nil, tint, grad)
    end
    local rows, tints = areas(1, 0, 1, 255)
    assert(not rows[0] and tints[0] == 13 / 20 and rows[4] == 7 / 20 and not tints[4],
           'full tint outside; the inside (row 4, past the 16 x 1 LUT) none')
    rows, tints = areas(-1, 0, 1, 255)
    assert(rows[0] == 13 / 20 and not tints[0], 'w < 0 inverts the gradient')
    rows, tints = areas(1, 0, 1, 128)
    local steps = math.floor(128 / 255 * S + 0.5)
    assert(tints[0] == 13 * steps / (20 * S) and rows[0] == 13 * (S - steps) / (20 * S), 'part way: ' .. steps)
    _, tints = areas(0.5, 0.5, 2, 255)
    assert(tints[0] == 13 * (S / 2) / (20 * S), 'strength 0.5 x saturate(2 x (1 - 0.5))')
    _, tints = areas(1, 0.5, 2, 64)
    assert(not tints[0], 'below the offset: no tint')
    rows, tints = Capes.areas(cells, 7, nil, tint, nil)
    assert(rows[0] == 13 / 20 and next(tints) == nil, 'no gradient: no tint')
end)

check('capes: a zone\'s border is the 8 neighbours of its cells that show another outside row, by row and by the tint '
      .. 'bin there; a zone past the LUT\'s height has none', function()
    local g = Capes.GRID
    local cells, grad = ffi.new('uint8_t[?]', g * g * 4), ffi.new('uint8_t[?]', g * g * 4)
    for i = 0, g * g - 1 do cells[i * 4 + 3], grad[i * 4] = 255, 255 end
    for y = 60, 63 do for x = 62, 65 do cells[(y * g + x) * 4 + 1] = 255 end end -- a 4 x 4 G square (row 2)
    local zones = Capes.zones(cells, 7)
    -- 16 cells x 8 neighbours = 128 pairs, 84 of them inside the square: 44 border cells, all row 0, no tint
    assert(zones[2] and zones[2][0][0] == 44 and next(zones[2], next(zones[2])) == nil, 'row 0 around the square')
    for k = 1, Capes.ZONE_BINS - 1 do assert(zones[2][0][k] == 0, 'bin ' .. k) end
    local values = ffi.new('float[64]')
    values[15], values[27] = 1, 1 -- row 0 fully tinted where the gradient is 1
    zones = Capes.zones(cells, 7, {values = values, width = 16, height = 1}, grad)
    assert(zones[2][0][Capes.ZONE_BINS - 1] == 44 and zones[2][0][0] == 0, 'the tinted border in the last bin')
    assert(Capes.zones(cells, 2) == nil, 'a LUT of 2 rows: no row-2 zone')
end)

check('cape zones: an emblem that read against its cloth and does not as planned takes the source color reading against '
      .. 'most of its border; one still reading stays; its own colors when no source color reads', function()
    local function row(key, r, area, L)
        return {key = key, lut = 'c', row = r, area = area, under = 0, L = L, a = 0, b = 0, metal = false,
                camo = false, mode = 1, full = false}
    end
    local zones = {[2] = {[0] = {[0] = 40, 0, 0, 0, 0, 0, 0, 0}}} -- the emblem borders only the cloth
    -- a dark cloth with a light emblem; a source of light and dark: both take its light, the emblem then its dark
    local target = Matcher.item({row('c:0', 0, 0.9, 30), row('c:2', 2, 0.1, 80)}, false)
    local source = item({{'s:0', 0.8, 75, 0, 0}, {'s:1', 0.2, 20, 0, 0}}, false)
    local plan = Matcher.plan(target, source, nil, true)
    assert(plan['c:0'].source == 's:0' and plan['c:2'].source == 's:0', 'the plan: both the light')
    Matcher.cape_zones(plan, target, source, zones, nil)
    assert(plan['c:2'].source == 's:1' and plan['c:2'].kind == 'zone' and plan['c:2'].L == 20, 'the emblem: the dark')
    assert(plan['c:0'].source == 's:0', 'the cloth keeps its color')
    -- a zone still reading as planned stays
    local apart = item({{'s:0', 0.8, 75, 0, 0}, {'s:1', 0.2, 20, 0, 0}}, false)
    local reading = Matcher.item({row('c:0', 0, 0.9, 80), row('c:2', 2, 0.1, 30)}, false)
    plan = Matcher.plan(reading, apart, nil, true)
    local before = plan['c:2'] and plan['c:2'].source
    Matcher.cape_zones(plan, reading, apart, zones, nil)
    assert(plan['c:2'] and plan['c:2'].source == before and plan['c:2'].kind ~= 'zone', 'a readable plan stays')
    -- a one-color source: no color reads, the emblem keeps its own (it reads against the new cloth)
    local one = item({{'s:0', 1.0, 60, 0, 0}}, false)
    local dark = Matcher.item({row('c:0', 0, 0.9, 62), row('c:2', 2, 0.1, 20)}, false)
    plan = Matcher.plan(dark, one, nil, true)
    assert(plan['c:2'], 'the emblem planned')
    Matcher.cape_zones(plan, dark, one, zones, nil)
    assert(plan['c:2'] == nil and plan['c:0'], 'the emblem keeps its own colors')
end)

check('cape zones: when no source color reads by lightness, a lost zone takes one reading by CIELAB distance before '
      .. 'its own colors (the UF-50 Bloodhound\'s red and black share a lightness)', function()
    local function row(key, r, area, L, a, b)
        return {key = key, lut = 'c', row = r, area = area, under = 0, L = L, a = a, b = b, metal = false,
                camo = false, mode = 1, full = false}
    end
    local zones = {[2] = {[0] = {[0] = 40, 0, 0, 0, 0, 0, 0, 0}}}
    local bloodhound = item({{'s:0', 0.62, 21, 20, 11}, {'s:1', 0.38, 21, 0, 0}}, false)
    -- the Pillars of Freedom: black cloth, red bars; the cloth takes the red and the bars too: they take the black
    local pillars = Matcher.item({row('c:0', 0, 0.9, 5, 0, 0), row('c:2', 2, 0.1, 34, 37, 27)}, false)
    local plan = Matcher.plan(pillars, bloodhound, nil, true)
    assert(plan['c:0'].source == 's:0' and plan['c:2'].source == 's:0', 'the plan: cloth and bars red')
    Matcher.cape_zones(plan, pillars, bloodhound, zones, nil)
    assert(plan['c:2'].source == 's:1' and plan['c:2'].kind == 'zone', 'the bars: black on the red')
    assert(plan['c:0'].source == 's:0', 'the cloth stays red')
    -- the Judgment Day: grey cloth, yellow marks (drawn by lightness: 39 apart); the cloth takes the black and the marks
    -- the red, the same lightness: no color reads by lightness and one drawn by lightness takes none reading by hue
    -- alone, so the marks keep their own yellow, readable on the black (the user chose "readable by lightness" knowing
    -- it changes the marks agreed red on 2026-10-07; independent review 1 2026-10-14: Proof of Faultless Virtue read plain
    -- red on the Bloodhound)
    local judgment = Matcher.item({row('c:0', 0, 0.9, 26, 0, 0), row('c:2', 2, 0.1, 65, -9, 55)}, false)
    plan = Matcher.plan(judgment, bloodhound, nil, true)
    local marks = plan['c:2'] and plan['c:2'].source
    assert(plan['c:0'].source == 's:1' and marks == 's:0', 'the plan: cloth black, marks red')
    Matcher.cape_zones(plan, judgment, bloodhound, zones, nil)
    assert(plan['c:2'] == nil, 'the marks keep their own yellow, readable by lightness, not the red')
    -- a source whose colors read neither way: the marks keep their own colors, as before
    local grey = item({{'s:0', 0.62, 27, 0, 0}, {'s:1', 0.38, 25, 1, 1}}, false)
    plan = Matcher.plan(judgment, grey, nil, true)
    Matcher.cape_zones(plan, judgment, grey, zones, nil)
    assert(plan['c:2'] == nil, 'no color reads: the marks keep their own colors')
end)

check('cape zones: a color picked by CIELAB distance reads against the zone\'s cloth too; a smaller source color '
      .. 'reading by lightness comes before own colors; zones of one color take one color', function()
    local function row(key, lut, r, area, L, a, b)
        return {key = key, lut = lut, row = r, area = area, under = 0, L = L, a = a, b = b, metal = false,
                camo = false, mode = 1, full = false}
    end
    local function goal(g) return {source = g[1], kind = 'pair', L = g[2], a = g[3], b = g[4]} end
    -- Strength in Our Arms on the CW-4 Arctic Ranger: a stripe mostly bordered by its outline, both planned brown on
    -- navy cloth; navy reads against the outline alone and would sink the stripe into the cloth
    local navy, brown = {'s:0', 21, -1, -8}, {'s:1', 28, 12, 26}
    local ranger = item({{'s:0', 0.6, 21, -1, -8}, {'s:1', 0.4, 28, 12, 26}}, false)
    local stripes = Matcher.item({row('c:0', 'c', 0, 0.8, 5, 0, 0), row('c:2', 'c', 2, 0.12, 35, 40, 30),
                                  row('c:3', 'c', 3, 0.08, 85, 0, 0)}, false)
    local plan = {['c:0'] = goal(navy), ['c:2'] = goal(brown), ['c:3'] = goal(brown)}
    local zones = {[2] = {[0] = {[0] = 20, 0, 0, 0, 0, 0, 0, 0}, [3] = {[0] = 80, 0, 0, 0, 0, 0, 0, 0}},
                   [3] = {[0] = {[0] = 50, 0, 0, 0, 0, 0, 0, 0}, [2] = {[0] = 50, 0, 0, 0, 0, 0, 0, 0}}}
    Matcher.cape_zones(plan, stripes, ranger, zones, nil)
    assert(plan['c:2'].source == 's:1', 'the stripe stays brown, not the navy of its cloth')
    -- the outline (white, drawn by lightness on the dark cloth) takes no color reading by hue alone: it keeps its own
    -- white, reading by lightness (independent review 1 2026-10-14, the user's "readable by lightness")
    assert(plan['c:3'] == nil, 'the outline keeps its own white, reading against the cloth')
    -- Liberty's Herald on the UF-50 Bloodhound: a gold chevron (arms row 1, V row 2) on cloth planned black where its
    -- tint is weak and red where it is strong; neither main color reads against both, the 1.8% silver does
    local bloodhound = item({{'s:0', 0.6, 21, 20, 11}, {'s:1', 0.38, 21, 0, 0}, {'s:2', 0.018, 40, 0, 0}}, false)
    local herald = Matcher.item({row('c:0', 'c', 0, 0.4, 25, 0, 0), row('ct:0', 'ct', 0, 0.4, 41, 0, 1),
                                 row('c:1', 'c', 1, 0.06, 65, -9, 55), row('c:2', 'c', 2, 0.05, 65, -9, 55)}, false)
    local red, black = {'s:0', 21, 20, 11}, {'s:1', 21, 0, 0}
    plan = {['c:0'] = goal(black), ['ct:0'] = goal(red), ['c:1'] = goal(red), ['c:2'] = goal(red)}
    zones = {[1] = {[0] = {[0] = 30, 0, 0, 0, 20, 0, 0, 30}},
             [2] = {[0] = {[0] = 60, 0, 0, 0, 0, 0, 0, 20}, [1] = {[0] = 20, 0, 0, 0, 0, 0, 0, 0}}}
    Matcher.cape_zones(plan, herald, bloodhound, zones, {ct = 'c'})
    assert(plan['c:1'].source == 's:2' and plan['c:1'].L == 40, 'the arms: silver, reading against black and red')
    assert(plan['c:2'].source == 's:2', 'the V: the arms\' silver too, not red')
end)

check('pysum adds as Python\'s sum() of floats (compensated since 3.12): the Cover of Darkness\'s paint sums to 1',
      function()
    local a = {0.5400885118937857, 0.0019177576986907615, 0.10799373040752351, 0.35}
    assert(a[1] + a[2] + a[3] + a[4] ~= 1.0 and Colour.pysum(a, 4) == 1.0, 'compensated')
    assert(Colour.pysum({}, 0) == 0 and Colour.pysum({0.1}, 1) == 0.1 and Colour.pysum({1, 2, 3}, 3) == 6,
           'empty, one value, integers')
end)

check('a cape tint is fitted on its base color alone (the shader blends column 0 only); the LUT stays', function()
    local transfer = Transfer.new(Colour, flat_model())
    local values = ffi.new('float[92]')
    local c = test_row()
    for k = 1, 92 do values[k - 1] = c[k] end
    local L, a, b = Colour.srgb_to_lab(0.3, 0.5, 0.7) -- a blue goal
    local r, g, bl, err = transfer.fit_base(values, 23, 0, {0.6, 0.1, 0.6}, {L = L, a = a, b = b})
    for k = 1, 92 do assert(values[k - 1] == tonumber(ffi.new('float', c[k])), 'the LUT row unchanged: value ' .. k) end
    local d = Colour.row_values(values, 23, 0) -- the row as the fit reads it (float32 values)
    d[1], d[2], d[3] = 0.6, 0.1, 0.6
    local before = {}
    for k = 1, 92 do before[k] = d[k] end
    local _, _, _, err2 = transfer.fit(d, L, a, b, nil, true)
    assert(err == err2 and r == d[1] and g == d[2] and bl == d[3], 'fit_base is a base-only fit of the tinted row')
    for k = 4, 92 do assert(d[k] == before[k], 'only the base moves: value ' .. k) end
    assert(err < 5, 'near the goal: dE ' .. err)
end)

check('glowing paint keeps its color like a lens: a LUT mod\'s glowing visor, the game\'s light strips (v1.3)',
      function()
    assert(Matcher.light({mode = 3}) and Matcher.light({mode = 0, emissive = 0.01}), 'a lens; glowing paint')
    assert(not Matcher.light({mode = 0, emissive = 0}) and not Matcher.light({mode = 0}), 'plain paint')
    assert(not Matcher.light({mode = 1, emissive = 1.0}), 'cloth uses column 13 otherwise')
    -- the A-35 Recon with a glow mod (user report 2026-10-06): its visor row is paint (mode 0) glowing green
    local rows = {{key = 't:0', area = 0.9, under = 0, L = 30, a = 0, b = 0, metal = false, camo = false, mode = 0,
                   full = false},
                  {key = 't:7', area = 0.1, under = 0, L = 88, a = -79, b = 81, metal = false, camo = false, mode = 0,
                   full = false, emissive = 0.01}}
    local source = item({{'s:0', 0.9, 50, 20, 30}, {'s:1', 0.1, 70, 0, 0}}, true)
    local plan = Matcher.plan(Matcher.item(rows, false), source)
    assert(plan['t:0'] and plan['t:7'] == nil, 'the glowing visor keeps its color')
    local helmet = Matcher.item(rows, false)
    for _, row in ipairs(helmet.paint) do assert(row.key ~= 't:7', 'and is no color of the helmet\'s palette') end
    rows[2].emissive = 0
    assert(Matcher.plan(Matcher.item(rows, false), source)['t:7'], 'without its glow it is paint and takes a color')
end)

check('trim rule: a large light area takes the main color, not a small trim (the 2026-10-05 gold suit)', function()
    -- v10 matched lightness: the armor's light 28% area took the helmet's 5% gold trim
    local target = item({{'t:0', 0.72, 24, 0, 0}, {'t:1', 0.28, 62, 0, 2}}, true)
    local source = item({{'s:0', 0.95, 25, 0, 0}, {'s:1', 0.05, 62, 3, 30}}, false)
    local plan = Matcher.plan(target, source)
    assert(plan['t:0'].source == 's:0' and plan['t:1'].source == 's:0' and plan['t:1'].kind == 'pair',
           'main color, not the trim: ' .. plan['t:1'].source)
end)

check('accents take the source accent color, even a small one; dark or already matching accents keep theirs; without '
      .. 'a source accent they take what the pairing gives', function()
    local target = item({{'t:0', 0.55, 30, 0, 0}, {'t:1', 0.28, 62, 0, 2}, {'t:2', 0.09, 50, 40, 40},
                         {'t:3', 0.05, 15, 30, 20}, {'t:4', 0.03, 60, 3, 30}}, true)
    local source = item({{'s:0', 0.88, 25, 0, 0}, {'s:1', 0.06, 60, 3, 30}, {'s:2', 0.06, 55, 50, -20}}, false)
    local plan = Matcher.plan(target, source)
    local accent = plan['t:2']
    assert(accent.kind == 'accent' and accent.source == 's:2' and accent.L == 55 and accent.a == 50 and accent.b == -20,
           'the accent takes the most salient source accent color')
    assert(plan['t:3'] == nil, 'a dark accent (L < 20) keeps its color')
    assert(plan['t:4'] == nil, 'an accent that already matches a source color keeps it')
    -- no source accent: with a second color the accent takes the pairing's color (it kept its own until v1.3: a yellow
    -- trim stayed on the DP-00 Tactical with the white and grey CW-36 Winter Warrior, user 2026-10-07); a one-color
    -- source leaves it its own, as its color would erase it (the RE-2310 Honorary Guard's gold with the AC-2 Obedient)
    local plain = Matcher.plan(target, item({{'s:0', 1.0, 25, 0, 0}}, false))
    assert(plain['t:2'] == nil and plain['t:0'].source == 's:0', 'a one-color source: the accent keeps its color')
    local two = Matcher.plan(target, item({{'s:0', 0.8, 25, 0, 0}, {'s:1', 0.2, 60, 0, 5}}, false))
    assert(two['t:2'] and two['t:2'].kind == 'pair', 'a second color: the accent takes the pairing\'s color')
    -- the Salamander and the B-01 (2026-10-05): a 25% orange takes the armor's 1% yellow; a 0.3% color or a dark one
    -- is no accent
    local wide = item({{'t:0', 0.70, 30, 0, 0}, {'t:1', 0.25, 60, 37, 58}}, true)
    local small = Matcher.plan(wide, item({{'s:0', 0.99, 21, 0, 0}, {'s:1', 0.01, 65, -9, 55}}, false))
    assert(small['t:1'] and small['t:1'].kind == 'accent' and small['t:1'].source == 's:1', 'a 1% accent counts')
    local tiny = Matcher.plan(wide, item({{'s:0', 0.997, 21, 0, 0}, {'s:1', 0.003, 65, -9, 55}}, false))
    assert(tiny['t:1'] == nil, 'a 0.3% color is no accent, nor a second color: the orange keeps its color')
    local dark = Matcher.plan(wide, item({{'s:0', 0.97, 21, 0, 0}, {'s:1', 0.03, 25, 20, 15}}, false))
    assert(dark['t:1'] and dark['t:1'].kind == 'pair',
           'a dark muted source color (a brown) is no accent but a second color: the orange takes the pairing\'s color')
    -- the CM-09 Bonesnapper armor's red trim (L 29, chroma 44): dark but vivid, it is the accent (v11.5)
    local red = Matcher.plan(wide, item({{'s:0', 0.97, 21, 0, 0}, {'s:1', 0.03, 29, 38, 21}}, false))
    assert(red['t:1'] and red['t:1'].source == 's:1', 'a vivid dark red is an accent')
end)

check('an armor\'s undersuit black goes only to dark parts; a green armor stays green (2026-10-05 reports)', function()
    -- the UF-84 Doubt Killer: glossy dark plates (L 24), an undersuit black (L 5, mostly undergarment), a red trim
    local doubt = item({{'s:0', 0.48, 24, 0, 0}, {'s:1', 0.47, 5, 1, 0, false, 0.6}, {'s:2', 0.05, 45, 64, 46}}, true)
    -- the CW-36 Winter Warrior helmet: a white shell and a dark part; v11.2 gave the shell the undersuit black
    local winter = Matcher.plan(item({{'t:0', 0.76, 69, 0, 8}, {'t:1', 0.24, 29, 0, 0}}, false), doubt)
    assert(winter['t:0'].source == 's:0', 'the white shell takes the plates, not the undersuit: '
           .. winter['t:0'].source)
    -- the RS-67 Null Cipher: a matte dark main and a glossy grey panel (L 36, not dark neutral)
    local cipher = Matcher.plan(item({{'t:0', 0.69, 22, 0, 0}, {'t:1', 0.29, 36, 0, 0}}, false), doubt)
    assert(cipher['t:1'].source == 's:0', 'the grey panel takes the plates: ' .. cipher['t:1'].source)
    -- the AD-49 Apollonian: a large dark part (17.5%, L 22) takes the plates too; only small dark parts may take it
    local apollo = Matcher.plan(item({{'t:0', 0.53, 33, -2, 7}, {'t:1', 0.18, 32, 0, 0, true}, {'t:2', 0.175, 22, 0, 0},
                                      {'t:3', 0.115, 54, 0, 4, true}}, false), doubt)
    assert(apollo['t:2'].source == 's:0', 'the large dark part takes the plates: ' .. apollo['t:2'].source)
    -- the TR-117 Alpha Commander: 48% scattered dark parts, 26% green plates, a dark green undersuit, tan pouches;
    -- the UF-50 Bloodhound helmet's red shell takes the green (dark parts weighed 0.75 made it dark grey)
    local alpha = item({{'s:0', 0.48, 24, 0, 0}, {'s:1', 0.26, 40, -11, 15}, {'s:2', 0.17, 31, -5, 5, false, 1.0},
                        {'s:3', 0.09, 57, 5, 17}}, true)
    local blood = Matcher.plan(item({{'t:0', 0.72, 31, 24, 13}, {'t:1', 0.18, 29, 0, 0}, {'t:2', 0.10, 54, 0, 4}},
                                    false), alpha)
    assert(blood['t:0'].source == 's:1', 'the red shell takes the green plates: ' .. blood['t:0'].source)
end)

check('capes: an emblem\'s sheet cell is recolored by its BC3 endpoints at every mip (alpha and indices kept, blocks '
      .. 'outside it untouched); a recipe leaves out a cell overlapping an earlier one', function()
    local Recolor, Colour = require('recolor'), require('colour')
    -- a 16 x 16 sheet with 3 mips (16, 4 and 1 blocks): every block's endpoints 0x39e7 and 0x0000
    local blocks = 16 + 4 + 1
    local data = ffi.new('uint8_t[?]', blocks * 16)
    for k = 0, blocks - 1 do
        for i = 0, 7 do data[k * 16 + i] = 0x11 * (i + 1) end -- the alpha block
        data[k * 16 + 8], data[k * 16 + 9], data[k * 16 + 10], data[k * 16 + 11] = 0xe7, 0x39, 0, 0
        for i = 12, 15 do data[k * 16 + i] = 0x5a end -- the color indices
    end
    Capes.recolor_sheet(data, {width = 16, height = 16, mips = 3}, {rect = {0, 0, 4, 4}, shift = {37.8, -3.6, 2.2}},
                        Colour) -- the top-left block of mip 0
    local function endpoint(k) return data[k * 16 + 8] + data[k * 16 + 9] * 256 end
    assert(endpoint(0) == 0x94d2, string.format('the reference endpoint: %04x', endpoint(0))) -- research/capes.py
    for k = 1, 15 do assert(endpoint(k) == 0x39e7, 'mip 0 block ' .. k .. ' outside the cell') end
    assert(endpoint(16) == 0x94d2 and endpoint(17) == 0x39e7 and endpoint(20) == 0x94d2, 'mips 1 and 2: the cell')
    for k = 0, blocks - 1 do
        for i = 0, 7 do assert(data[k * 16 + i] == 0x11 * (i + 1), 'alpha kept') end
        for i = 12, 15 do assert(data[k * 16 + i] == 0x5a, 'indices kept') end
    end
    local function emblem(rect, L) return {rect = rect, L = L, a = 0, b = 0, sheet = 's', sheet_width = 2048,
                                           sheet_height = 2048, sheet_mips = 12, sheet_format = 77} end
    local target = {emblems = {emblem({0, 0, 100, 100}, 20), emblem({50, 50, 150, 150}, 30), emblem({200, 0, 300, 50}, 40),
                               emblem({400, 0, 500, 50}, 50)}}
    local pick = {L = 60.3, a = -1.2, b = 0.5}
    local recipe = Recolor.sheet_recipe(target, {pick, pick, pick})
    assert(recipe and recipe.size == 5592432 and #recipe.cells == 2, 'the overlapping second cell left out, the fourth not '
           .. 'picked')
    assert(recipe.cells[1].shift[1] == math.floor(40.3 * 1024 + 0.5) / 1024 and recipe.cells[2].rect[1] == 200,
           'shifts in 1/1024 steps')
    target.emblems[1].sheet_format = 28 -- a placeholder (RGBA8) sheet: never recolored
    assert(Recolor.sheet_recipe(target, {pick}) == nil, 'no recipe for a placeholder sheet')
end)

check('a speck accent (under 1%) recolors a bigger accent only within its hue family; a light neutral pattern takes '
      .. 'the source\'s nearest neutral, when it has two (image review 2026-10-07)', function()
    -- an all-dark helmet with a grey and a 0.6% yellow mark (the RS-67 Null Cipher's kind)
    local cipher = item({{'s:0', 0.64, 27, 1, 0}, {'s:1', 0.30, 29, 0, -2}, {'s:2', 0.054, 51, 0, 0},
                         {'s:3', 0.006, 64, -9, 54}}, false)
    -- an armor: dark, a green suit, 3% red canisters, a cream pattern (the CM-14 Physician's kind)
    local physician = item({{'t:0', 0.55, 25, 0, 0}, {'t:1', 0.42, 40, -30, 7}, {'t:2', 0.03, 32, 41, 27}}, true,
                           {{pattern = 'dddddddddddddddd', area = 0.16, r = 0.66, g = 0.633, b = 0.566}})
    local plan = Matcher.plan(physician, cipher)
    assert(plan['t:2'] and plan['t:2'].kind == 'pair' and plan['t:2'].source ~= 's:3',
           'the red canisters take the pairing, not the yellow speck')
    local cream = Matcher.pattern_plan(physician, cipher).dddddddddddddddd
    assert(cream and cream.source == 's:2', 'the cream pattern takes the grey')
    -- the same speck in the canisters' hue family (an orange-red mark) still recolors them
    local orange = item({{'s:0', 0.64, 27, 1, 0}, {'s:1', 0.30, 29, 0, -2}, {'s:2', 0.054, 51, 0, 0},
                         {'s:3', 0.006, 49, 30, 30}}, false)
    plan = Matcher.plan(physician, orange)
    assert(plan['t:2'] and plan['t:2'].kind == 'accent' and plan['t:2'].source == 's:3', 'a speck of its hue family')
    -- a source with one neutral paint (dark plates and a red trim) leaves a light neutral pattern its own color
    local doubt = item({{'s:0', 0.90, 24, 0, 0}, {'s:1', 0.10, 45, 64, 46}}, true)
    assert(Matcher.pattern_plan(physician, doubt).dddddddddddddddd == nil, 'one neutral: the pattern keeps its color')
end)

check('accents of any size and pattern accents take the source accent; a pattern can be it (2026-10-05)', function()
    local YELLOW = {0.668, 0.625, 0.195} -- the common pattern texture's color (Lab 65 -9 56)
    -- the UF-84 Doubt Killer: dark plates, undersuit black, a 5% red trim
    local doubt = item({{'s:0', 0.48, 24, 0, 0}, {'s:1', 0.47, 5, 1, 0, false, 0.6}, {'s:2', 0.05, 45, 64, 46}}, true)
    -- the RS-67 Null Cipher's 0.9% yellow: below the pairing minimum, still an accent
    local cipher = Matcher.plan(item({{'t:0', 0.69, 22, 0, 0}, {'t:1', 0.30, 36, 0, 0}, {'t:2', 0.009, 63, -9, 54}},
                                     false), doubt)
    assert(cipher['t:2'] and cipher['t:2'].kind == 'accent' and cipher['t:2'].source == 's:2',
           'the small yellow takes the red')
    -- the FS-23 Battle Master: its yellow stripes are a pattern; they take the red
    local battle = item({{'t:0', 0.55, 31, 0, 0}, {'t:1', 0.45, 43, 0, 0}}, false,
                        {{pattern = 'aaaaaaaaaaaaaaaa', area = 0.13, r = YELLOW[1], g = YELLOW[2], b = YELLOW[3]},
                         {pattern = 'cccccccccccccccc', area = 0.05, r = 0.9, g = 0.9, b = 0.85}})
    local stripes = Matcher.pattern_plan(battle, doubt)
    local red = stripes.aaaaaaaaaaaaaaaa
    assert(red and red.source == 's:2' and red.L == 45 and red.a == 64 and red.b == 46,
           'the yellow pattern takes the red')
    assert(stripes.cccccccccccccccc == nil, 'a neutral pattern keeps its color')
    -- an armor whose only accent is a pattern (yellow, 2%): the pattern is its accent; a matching pattern keeps
    local b01 = item({{'s:0', 1.0, 21, 0, 0}}, true,
                     {{pattern = 'bbbbbbbbbbbbbbbb', area = 0.02, r = YELLOW[1], g = YELLOW[2], b = YELLOW[3]}})
    local salamander = Matcher.plan(item({{'t:0', 0.70, 45, 1, 1}, {'t:1', 0.30, 60, 37, 58}}, false), b01)
    assert(salamander['t:1'] and salamander['t:1'].source == 'pattern:bbbbbbbbbbbbbbbb',
           'the orange accent takes the armor\'s yellow pattern')
    assert(Matcher.pattern_plan(battle, b01).aaaaaaaaaaaaaaaa == nil,
           'a pattern that already matches the source accent keeps its color')
    -- a cape of one color repaints a pattern accent with its identity ("repaint for capes"; fresh gallery case 37: the
    -- FS-23 Battle Master's yellow stripes under the dark grey e7619545); a helmet or armor of one color leaves it
    local grey = item({{'g:0', 1.0, 22, 0, 0}}, false)
    assert(Matcher.pattern_plan(battle, grey).aaaaaaaaaaaaaaaa == nil, 'a one-color helmet source: the pattern stays')
    grey.cape_source = true
    local repainted = Matcher.pattern_plan(battle, grey).aaaaaaaaaaaaaaaa
    assert(repainted and repainted.source == 'g:0' and repainted.L == 22, 'a one-color cape: the pattern takes its grey')
end)

check('a neutral color with a part\'s gloss floor takes at most Colour.GLOSS_TINT_C of the floor\'s tint (fresh gallery '
      .. '2026-10-11, case 103: the FS-05 Marksman\'s dome under a black cape aimed at its cyan floor\'s teal); a slight '
      .. 'cast and a colored goal stay as they were', function()
    local cyan = {0.538, 0.532, 0.536, 0.0017, 0.052, 0.0518}
    local L, a, b = Colour.with_gloss(9.2, 0, 0, cyan)
    assert(math.sqrt(a * a + b * b) <= Colour.GLOSS_TINT_C + 1e-9 and L > 20,
           string.format('black under a cyan floor: L %.1f a %.1f b %.1f', L, a, b))
    local warm = {1.08, 1.0, 0.87, 0.012, 0.010, 0.007}
    local wL, wa, wb = Colour.with_gloss(25, 0, 0, warm)
    local r, g, bl = Colour.lab_to_linear(25, 0, 0)
    local eL, ea, eb = Colour.linear_to_lab(r + warm[4], g + warm[5], bl + warm[6])
    assert(math.abs(wL - eL) < 1e-9 and math.abs(wa - ea) < 1e-9 and math.abs(wb - eb) < 1e-9,
           'a slight warm cast stays in full')
    local cL, ca, cb = Colour.with_gloss(30, 8, 6, cyan)
    local w = 1 - 10 / Colour.GLOSS_C -- chroma 10
    r, g, bl = Colour.lab_to_linear(30, 8, 6)
    eL, ea, eb = Colour.linear_to_lab(r + w * cyan[4], g + w * cyan[5], bl + w * cyan[6])
    assert(math.abs(cL - eL) < 1e-9 and math.abs(ca - ea) < 1e-9 and math.abs(cb - eb) < 1e-9,
           'a colored goal keeps the floor\'s tint')
end)

check('Match Cape: a cape\'s second main color (25% or more, apart from its identity, mostly outside) takes the largest '
      .. 'near-neutral main part the search left without it (fresh gallery 2026-10-11, case 36: the BP-32 Jackboot all '
      .. 'black under 1264718e\'s 37% yellow); a colored part keeps its band, a lining color stays out', function()
    local out = {{area = 1, outside = 1}}
    local lim = {second = 0.25, main = 0.10, keep = 8.0, own_c = 9.0}
    local function cape(second_rows, yellow)
        return {{share = 0.63, L = 25.7, a = 0, b = 0, rows = out},
                {share = 0.37, L = yellow and 64.7 or 27, a = yellow and -8.8 or 0, b = yellow and 55.5 or 1,
                 rows = second_rows or out}}
    end
    local t = {{share = 0.47, ma = 0, mb = 0}, {share = 0.30, ma = 0, mb = 9.7}, {share = 0.16, ma = 0, mb = 0.3},
               {share = 0.06, ma = 0, mb = 0}}
    local function assigned(s, allowed, assign)
        assign = assign or {1, 1, 1, 1}
        Colour.cape_second({t = t, s = s, allowed = allowed or {{true, true}, {true, true}, {true, true}, {true, true}}},
                           assign, 1, 1, lim)
        return assign
    end
    local a = assigned(cape(nil, true))
    assert(a[3] == 2 and a[2] == 1 and a[1] == 1 and a[4] == 1, 'the near-neutral 16% part takes the yellow, the colored '
           .. '30% part keeps its pair: ' .. table.concat(a, ','))
    a = assigned(cape(nil, true), nil, {1, 2, 1, 1})
    assert(a[3] == 1, 'a main part already showing it: no change')
    a = assigned(cape({{area = 1, outside = 0}}, true))
    assert(a[3] == 1, 'a lining color: no change')
    a = assigned(cape(nil, false))
    assert(a[3] == 1, 'a second color like the identity: no change')
    a = assigned(cape(nil, true), {{true, true}, {true, true}, {true, false}, {true, true}})
    assert(a[3] == 1, 'a part that may not take it: no change')
end)

check('Match Cape: under a cape of no dark neutral an undersuit takes the nearest by lightness of its main colors that '
      .. 'the cape\'s part guard allows it; with none it keeps its color (fresh gallery 2026-10-11, case 80: the IE-3 '
      .. 'Martyr\'s olive undersuit under Federation\'s Embrace\'s blue and gold)', function()
    local out, inside = {{area = 1, outside = 1}}, {{area = 1, outside = 0}}
    local lim = {main = 0.10, keep = 8.0, accent_c = 20.0}
    local function pick(palette, group)
        local pairs, used = {}, {}
        Colour.cape_structure({group}, palette, Capes.dark_parts_guard, lim, pairs, used)
        return pairs[1] and pairs[1][2], used
    end
    local suit = {L = 22, a = 2, b = 6, mL = 22, ma = 2, mb = 6, share = 0.4}
    local blue = {L = 37.5, a = -1.7, b = -19.5, ma = -1.7, mb = -19.5, share = 0.92, rows = out}
    local gold = {L = 66, a = -0.5, b = 29.8, ma = -0.5, mb = 29.8, share = 0.08, rows = out}
    local n, used = pick({blue, gold}, suit)
    assert(n == blue and math.abs(used[blue] - 0.4) < 1e-12, 'blue and gold: the blue')
    local cream = {L = 81.5, a = 0.4, b = 11.8, ma = 0.4, mb = 11.8, share = 0.655, rows = out}
    local slate = {L = 37.1, a = -0.4, b = -6.3, ma = -0.4, mb = -6.3, share = 0.276, rows = out}
    local red = {L = 36.3, a = 35, b = 19.5, ma = 35, mb = 19.5, share = 0.07, rows = out}
    assert(pick({cream, slate, red}, suit) == slate, 'the Drape of Glory: the blue-grey, not its 7% red')
    local cream60 = {L = 60.2, a = 4.5, b = 18.5, ma = 4.5, mb = 18.5, share = 0.62, rows = out}
    local taupe = {L = 39.5, a = 3.7, b = 9.6, ma = 3.7, mb = 9.6, share = 0.33, rows = inside}
    assert(pick({cream60, taupe, red}, suit) == nil, 'a light cream and a tinted lining only: it keeps its color')
end)

check('the CM-09 Bonesnapper armor: cream plates are its main color, its red trim the accent (2026-10-05)', function()
    -- 56% dark parts (harness, plate backs), a green undersuit (17%, all undergarment), cream plates (16%), a vivid
    -- dark red trim (2%); v11.4 made the helmets grey (dark identity) with the cape piece's yellow as the accent
    local bonesnapper = item({{'s:0', 0.56, 24, 0, 0}, {'s:1', 0.17, 30, -12, 6, false, 1.0}, {'s:2', 0.16, 68, 1, 7},
                              {'s:3', 0.05, 61, -1, 0, true}, {'s:4', 0.02, 29, 38, 21}}, true)
    -- the I-44 Salamander: bare-metal shell, a dark part, an orange accent
    local salamander = Matcher.plan(item({{'t:0', 0.60, 45, 1, 1, true}, {'t:1', 0.28, 22, 0, 0},
                                          {'t:2', 0.10, 60, 37, 58}}, false), bonesnapper)
    assert(salamander['t:0'].source == 's:2', 'the shell takes the cream plates: ' .. salamander['t:0'].source)
    assert(salamander['t:1'].source == 's:0', 'the dark part stays dark: ' .. salamander['t:1'].source)
    assert(salamander['t:2'].kind == 'accent' and salamander['t:2'].source == 's:4', 'the orange takes the red')
    -- the DS-10 Big Game Hunter: a dark mask (70%) and a muted tan hood (26%): the hood is no accent; the cream goes
    -- to the hood, the mask stays dark
    local hunter = Matcher.plan(item({{'t:0', 0.70, 23, 1, 5}, {'t:1', 0.26, 40, 2, 30}}, false), bonesnapper)
    assert(hunter['t:1'].kind == 'pair' and hunter['t:1'].source == 's:2', 'the hood takes the cream: '
           .. hunter['t:1'].kind .. ' ' .. hunter['t:1'].source)
    assert(hunter['t:0'].source == 's:0', 'the mask stays dark: ' .. hunter['t:0'].source)
    -- a muted tan part of 26% beside a cream main is a main part, not an accent: it is paired, not made red
    local banded = Matcher.plan(item({{'t:0', 0.70, 70, 1, 7}, {'t:1', 0.26, 40, 2, 30}}, false), bonesnapper)
    assert(banded['t:1'].kind == 'pair', 'a large muted part is paired: ' .. banded['t:1'].kind)
end)

check('pattern textures: texel 0 takes the planned color in sRGB, the mask layer and controls stay', function()
    local values = ffi.new('float[12]', {0.668, 0.625, 0.195, 0, 0, 0, 0, 1, 0, 0, 0, 0.3})
    local target = {luts = {aaaaaaaaaaaaaaaa = {values = values, width = 3, height = 1}}}
    local out = Recolor.build_patterns(target, {aaaaaaaaaaaaaaaa = {L = 45, a = 64, b = 46}}, Colour)
    local spec = assert(out.aaaaaaaaaaaaaaaa, 'pattern texture built')
    local r, g, b = Colour.lab_to_srgb(45, 64, 46)
    assert(spec.width == 3 and spec.height == 1, 'size')
    for i, want in ipairs({r, g, b}) do
        assert(math.abs(spec.data[i - 1] - want) < 1e-6, 'texel 0 channel ' .. i)
    end
    for i = 3, 11 do assert(spec.data[i] == values[i], 'value ' .. i .. ' kept') end
    assert(values[0] == tonumber(ffi.new('float', 0.668)), 'the vanilla texels are untouched')
end)

check('bare metal taking paint aims for the paint\'s 0.04 white reflection more (the 2026-10-05 Salamander)', function()
    -- a neutral at lightness L with `lift` linear light added, by the CIELAB formula alone
    local function lifted(L, lift)
        return 116 * (((L + 16) / 116) ^ 3 + lift) ^ (1 / 3) - 16
    end
    local function near(got, want, what)
        assert(math.abs(got.L - want) < 1e-3 and math.abs(got.a) < 1e-3 and math.abs(got.b) < 1e-3,
               string.format('%s: L %.4f a %.4f b %.4f, expected L %.4f', what, got.L, got.a, got.b, want))
    end
    -- the Salamander's metal shell and dark paint take the B-01's dark paint (model L21)
    local helmet = item({{'t:0', 0.70, 45, 1, 1, true}, {'t:1', 0.30, 22, 0, 0}}, false)
    local plan = Matcher.plan(helmet, item({{'s:0', 1.0, 21, 0, 0}}, true))
    near(plan['t:0'], lifted(21, 0.04), 'the metal row aims for the paint plus its reflection')
    near(plan['t:1'], 21, 'the paint row takes the paint as it is')
    -- the other direction: paint takes the metal's color without the reflection taken away (taking it away turned
    -- paint black below L 23: the FS-37 Ravager helmet from the PH-202 Twigsnapper's dark bronze, 2026-10-05), only
    -- the sets' metal shift scaled to the metal's lightness (2026-10-09): the helmet 2.8 x 23 / 36.6 darker, never black
    local back = Matcher.plan(item({{'t:0', 1.0, 21, 0, 0}}, false), item({{'s:0', 1.0, 23, 0, 0, true}}, true))
    near(back['t:0'], 23 - 2.8 * 23 / 36.6, 'the helmet paint takes the dark bronze, barely darker')
    assert(back['t:0'].L > 20, 'never black')
    -- an armor's matte paint from a helmet's metal: the sets' 9.4 L darker at L 36.6, scaled (the CPR-80 Bulwark's own
    -- armor L 30 against its helmet steel's L 39; user 2026-10-09: armors from it "way too bright")
    local steel = Matcher.plan(item({{'t:0', 1.0, 21, 0, 0}}, true), item({{'s:0', 1.0, 39.4, 0, 0, true}}, false))
    near(steel['t:0'], 39.4 - 9.4 * 39.4 / 36.6, 'the armor paint from the helmet steel, darker')
    -- metal against metal: as it is
    local same = Matcher.plan(item({{'t:0', 1.0, 45, 0, 0, true}}, false), item({{'s:0', 1.0, 60, 0, 0, true}}, true))
    near(same['t:0'], 60, 'a metal row takes a metal color as it is')
end)

check('new LUTs fit the planned rows only and leave the vanilla data alone', function()
    local function lut(height)
        local values = ffi.new('float[?]', 23 * height * 4)
        for i = 0, 23 * height * 4 - 1 do values[i] = i end
        return {values = values, width = 23, height = height}
    end
    local target = {luts = {aaaaaaaaaaaaaaaa = lut(8)}}
    local calls, yields = {}, 0
    local transfer = {apply = function(values, width, row, goal)
        calls[#calls + 1] = {row, goal.L, goal.a, goal.b}
        values[row * width * 4] = -1
        return 0
    end}
    local plan = {['aaaaaaaaaaaaaaaa:2'] = {source = 'bbbbbbbbbbbbbbbb:3', kind = 'pair', L = 40, a = 1, b = 2}}
    local out = Recolor.build_luts(target, plan, transfer, function() yields = yields + 1 end)
    assert(#calls == 1 and calls[1][1] == 2 and calls[1][2] == 40 and calls[1][4] == 2 and yields == 1, 'one fit')
    local data = out.aaaaaaaaaaaaaaaa.data
    for i = 0, 23 * 8 * 4 - 1 do
        assert(data[i] == (i == 2 * 92 and -1 or i), 'value ' .. i)
        assert(target.luts.aaaaaaaaaaaaaaaa.values[i] == i, 'vanilla value ' .. i)
    end
end)

-- Matcher v12: measured items (the Armory front view's screen pixels and each row's measured response). A row of
-- {key, texture area, model L, a, b, screen pixels[, bare metal[, undergarment fraction[, cal[, light]]]]} gets the
-- albedo of its model color, so a row with cal = {1, 1, 1, 0, 0, 0} looks as its model color; light (pixels x mean
-- screen luminance) defaults to pixels x the luminance of that color; look: the kit's appearance entry.
local function measured(rows, armor, patterns)
    local out, kit, cals = {}, {luts = {}, rows = {}, patterns = {}}, {}
    for i, r in ipairs(rows) do
        local lut, row = r[1]:match('^(%w+):(%d+)$')
        local ar, ag, ab = Colour.lab_to_linear(r[3], r[4], r[5])
        out[i] = {key = r[1], lut = lut, row = tonumber(row), area = r[2], under = r[2] * (r[8] or 0), L = r[3],
                  a = r[4], b = r[5], metal = r[7] == true, camo = false, mode = 0, full = r[7] == true, ar = ar,
                  ag = ag, ab = ab}
        kit.luts[lut] = true
        local _, y = Colour.lab_to_linear(r[3], r[4], r[5]) -- the green channel stands in for luminance
        if r[6] > 0 then kit.rows[r[1]] = {r[6], r[10] or math.floor(r[6] * y + 0.5)} end
        cals[r[1]] = r[9] or {1, 1, 1, 0, 0, 0}
    end
    local look = {kit = kit, row = function(lut, row) return cals[lut .. ':' .. row] end}
    return Matcher.item(out, armor, patterns, look), Matcher.item(out, armor, patterns)
end

check('v12: a dark armor with a light main part showing more light reads as that part (SR-64 Cinderblock)', function()
    -- screen: dark plates and straps 72% (L 21), light chest plate and shoulders 19% (L 43); the light part shows
    -- more light (pixels x screen luminance), so helmets take the light grey, not the straps (user 2026-10-05)
    local rows = {{'c:0', 0.66, 21, 0, 0, 7170, false, 0.05, nil, 8565}, {'c:1', 0.15, 43, 0, 0, 1880, false, 0, nil,
                  12847}}
    local cinder = measured(rows, true)
    local salamander = measured({{'t:0', 0.6, 45, 1, 1, 7750, true}, {'t:1', 0.3, 22, 0, 0, 1460}}, false)
    local plan = Matcher.plan(salamander, cinder)
    assert(plan['t:0'].source == 'c:1', 'the light shell takes the light plates: ' .. plan['t:0'].source)
    assert(plan['t:1'].source == 'c:0', 'the dark part takes the dark color: ' .. plan['t:1'].source)
    -- a one-part helmet takes the identity itself
    local plain = measured({{'t:0', 1.0, 40, 0, 0, 9000}}, false)
    assert(Matcher.plan(plain, cinder)['t:0'].source == 'c:1', 'the identity is the light part')
    rows[2][10] = 4000 -- the light part shows less light than the dark one: the dark one stays the identity
    assert(Matcher.plan(plain, measured(rows, true))['t:0'].source == 'c:0', 'dark identity kept')
    rows[2][6], rows[2][10] = 1100, 12847 -- a light part under LARGE_AREA (11%) is no identity
    assert(Matcher.plan(plain, measured(rows, true))['t:0'].source == 'c:0', 'small light part')
end)

check('an armor whose undersuit black is nearly all it shows reads as that black (SC-34 Infiltrator, 2026-10-06)', function()
    -- screen: 93% dark grey (L 25), more than half of it undersuit, and 2% light-grey trims (L 61): the trims had
    -- become the identity and turned the base of helmets white (user, real play)
    local infiltrator = measured({{'i:0', 0.93, 25, 0, 0, 9200, false, 0.57}, {'i:1', 0.02, 61, -1, 0, 220, false, 0.11}},
                                 true)
    assert(infiltrator.suit_paint, 'no paint color of its own reaches LARGE_AREA')
    local helmet = measured({{'t:0', 0.8, 51, -4, 15, 8100}, {'t:1', 0.17, 22, 0, 0, 1700}}, false)
    local plan = Matcher.plan(helmet, infiltrator)
    assert(plan['t:0'].source == 'i:0' and plan['t:1'].source == 'i:0', 'the base dark like the suit: '
           .. plan['t:0'].source)
    -- a 12% light part is still no paint color of its own (the IE-3 Martyr's chest plate): the identity is the suit,
    -- which a one-part helmet takes (a two-tone helmet's light part may still take the plate, a main color)
    local martyr = measured({{'i:0', 0.85, 25, 0, 0, 8500, false, 0.6}, {'i:1', 0.12, 67, 1, 7, 1200, false, 0}}, true)
    local plain = measured({{'t:0', 1.0, 40, 0, 0, 9000}}, false)
    assert(martyr.suit_paint and Matcher.plan(plain, martyr)['t:0'].source == 'i:0', 'the Martyr reads dark')
    -- the suit may go to a large part too: a mid-grey shell beside a dark part takes the suit, not the 12% plate
    local grey = measured({{'t:0', 0.8, 38, 0, 0, 8100}, {'t:1', 0.17, 22, 0, 0, 1700}}, false) -- not a keep match
    assert(Matcher.plan(grey, martyr)['t:0'].source == 'i:0', 'a mid-grey shell takes the suit')
    -- with a paint color of its own (20%) the undersuit black stays undersuit: a light shell keeps away from it
    local plates = measured({{'i:0', 0.75, 25, 0, 0, 7500, false, 0.6}, {'i:1', 0.2, 61, -1, 0, 2000, false, 0}}, true)
    assert(not plates.suit_paint, 'a 20% paint color of its own')
    assert(Matcher.plan(helmet, plates)['t:0'].source == 'i:1', 'the light shell takes the paint, not the undersuit')
    -- a helmet never counts its dark parts as an undersuit
    assert(not helmet.suit_paint, 'helmets keep the rule as it was')
end)

check('v12: the helmet\'s main part takes the identity, not a smaller part that already matches it', function()
    -- the FS-23 Battle Master from the SR-64 Cinderblock (identity: its light plates, 19%; 72% dark): the shell (L 33,
    -- a medium grey, not dark, just over the match distance from L 43) takes the light grey; its light part (L 47),
    -- which already matches the light grey, does not anchor it
    local cinder = measured({{'c:0', 0.66, 21, 0, 0, 7170, false, 0.05, nil, 8565},
                             {'c:1', 0.15, 43, 0, 0, 1880, false, 0, nil, 12847}}, true)
    local battle = measured({{'t:0', 0.6, 33, 0, 0, 5840}, {'t:1', 0.2, 47, 0, 0, 1990}}, false)
    local plan = Matcher.plan(battle, cinder)
    assert(plan['t:0'].source == 'c:1', 'the main shell takes the light identity: ' .. plan['t:0'].source)
end)

check('v12: a part that already matches a main source color keeps it (no black crest, 2026-10-05)', function()
    -- the FS-23 Battle Master's light crest (L 47) already matches the SR-64 Cinderblock's light plates (L 43, a main
    -- color); mirroring the armor's 72% dark had turned it black
    local cinder = measured({{'c:0', 0.66, 21, 0, 0, 7170, false, 0.05, nil, 8565},
                             {'c:1', 0.15, 43, 0, 0, 1880, false, 0, nil, 12847}}, true)
    local battle = measured({{'t:0', 0.6, 33, 0, 0, 5840}, {'t:1', 0.2, 47, 0, 0, 1990}}, false)
    assert(Matcher.plan(battle, cinder)['t:1'].source == 'c:1', 'the light crest stays light')
    -- a match to a minor source color (under MAIN_COLOR) does not hold: the DS-191 Scorpion's beige suit goes dark
    local cap = measured({{'s:0', 0.8, 20, 0, 0, 9000}, {'s:1', 0.05, 56, 0, 3, 470}}, false)
    local scorpion = measured({{'t:0', 0.4, 26, 0, 0, 2180}, {'t:1', 0.4, 56, 3, 10, 3800}}, true)
    assert(Matcher.plan(scorpion, cap)['t:1'].source == 's:0', 'a minor color match does not hold')
end)

check('v12: a measured armor\'s small visible emblem is its accent (the SR-64 Cinderblock\'s orange, 2026-10-05)', function()
    -- 0.12% of its pixels, below v11.5's 0.5% texture floor
    local rows = {{'c:0', 0.8, 21, 0, 0, 7170}, {'c:1', 0.2, 43, 0, 0, 1880}, {'c:2', 0.0005, 54, 35, 50, 11}}
    local cinder, cinder_texture = measured(rows, true)
    local salamander = measured({{'t:0', 0.8, 45, 1, 1, 7750, true}, {'t:1', 0.07, 60, 37, 58, 730}}, false)
    local plan = Matcher.plan(salamander, cinder)
    assert(plan['t:1'] and plan['t:1'].kind == 'accent' and plan['t:1'].source == 'c:2', 'the orange takes the emblem')
    local texture = Matcher.plan(salamander, cinder_texture)['t:1']
    assert(texture and texture.kind == 'pair', 'on texture shares (0.05%) there is no accent: the pairing\'s color')
end)

check('v12: a row the Armory never shows is no accent (the SR-64 Cinderblock\'s lime, 2026-10-05)', function()
    -- texture: lime 1.6% (vivid, the most salient accent); screen: never seen
    local cinder, cinder_texture = measured({{'c:0', 0.66, 23, 0, 0, 715}, {'c:1', 0.15, 33, 0, 0, 190},
                                             {'c:2', 0.016, 87, -86, 83, 0}}, true)
    local salamander = Matcher.item({{key = 't:0', lut = 't', row = 0, area = 0.6, under = 0, L = 45, a = 1, b = 1,
                                      metal = true, camo = false, mode = 0, full = true},
                                     {key = 't:1', lut = 't', row = 1, area = 0.1, under = 0, L = 60, a = 37, b = 58,
                                      metal = false, camo = false, mode = 0, full = false}}, false)
    assert(cinder.measured and not cinder_texture.measured, 'measured with its look')
    assert(Matcher.plan(salamander, cinder)['t:1'] == nil, 'the orange keeps its color: no source accent, one color')
    local mutant = Matcher.plan(salamander, cinder_texture)['t:1']
    assert(mutant and mutant.source == 'c:2', 'on texture shares the lime is the accent (v11.5)')
end)

check('v12: the I-92 Fire Fighter\'s identity is its grey, not its tan padding (2026-10-05)', function()
    -- screen: grey plates 42.6% (dark neutral, partly undersuit), blue coat 20.8% (undersuit), brown 12.6%, tan 4.8%;
    -- texture: grey 27%, blue 18%, brown 8%, tan 11%
    local rows = {{'f:0', 0.27, 26, 0, 0, 4260, false, 0.43}, {'f:1', 0.18, 32, -1, -12, 2080, false, 1.0},
                  {'f:2', 0.08, 12, 5, 17, 1260, false, 0.67}, {'f:3', 0.11, 48, 8, 17, 480}}
    local fire, fire_texture = measured(rows, true)
    local salamander = Matcher.item({{key = 't:0', lut = 't', row = 0, area = 0.8, under = 0, L = 45, a = 1, b = 1,
                                      metal = true, camo = false, mode = 0, full = true}}, false)
    assert(Matcher.plan(salamander, fire)['t:0'].source == 'f:0', 'the shell takes the grey')
    assert(Matcher.plan(salamander, fire_texture)['t:0'].source == 'f:3', 'on texture shares: the tan (v11.5)')
end)

check('v12: a part takes the source\'s look, without the paint-reflection lift (Doubt Killer greys, 2026-10-05)', function()
    -- the plates look as their model color (L 24); the Salamander's metal shell (model L 45) looks L 34
    local doubt, doubt_texture = measured({{'d:0', 0.47, 24, 0, 0, 4640}, {'d:1', 0.48, 5, 1, 0, 5170, false, 0.83}},
                                          true)
    local shell = {0.5, 0.5, 0.5, 0, 0, 0} -- s + g x albedo: half the light of the model color
    local salamander, salamander_texture = measured({{'t:0', 0.6, 45, 1, 1, 9000, true, 0, shell}}, false)
    local r, g, b = Colour.lab_to_linear(45, 1, 1)
    assert(math.abs(salamander.groups[1].L - Colour.linear_to_lab(r * 0.5, g * 0.5, b * 0.5)) < 1e-9,
           'the shell looks as its response says')
    local goal = Matcher.plan(salamander, doubt)['t:0']
    assert(goal.source == 'd:0' and math.abs(goal.L - 24) < 1e-4 and goal.cal == shell,
           'the plates as they look, fitted through the shell\'s response: L ' .. goal.L)
    local lifted = Matcher.plan(salamander_texture, doubt_texture)['t:0']
    assert(lifted.L > 30 and lifted.cal == nil, 'unmeasured bare metal keeps the v11.2 lift: L ' .. lifted.L)
end)

check('v12: rows of one model color stay one group, colored by their pixels', function()
    local item = measured({{'s:0', 0.5, 45, 0, 0, 3000, true, 0, {0.6, 0.6, 0.6, 0, 0, 0}},
                           {'s:1', 0.5, 45, 0, 0, 1000, true, 0, {0.3, 0.3, 0.3, 0, 0, 0}}}, false)
    assert(#item.groups == 1, 'one group: ' .. #item.groups)
    local r, g, b = Colour.lab_to_linear(45, 0, 0)
    local k = (3000 * 0.6 + 1000 * 0.3) / 4000
    local want = Colour.linear_to_lab(r * k, g * k, b * k)
    assert(math.abs(item.groups[1].L - want) < 1e-6 and item.groups[1].mL == 45, 'pixel-weighted look, model class')
end)

check('v12: the fit goes through the row\'s response; a reflection floor bounds how dark it can look', function()
    local transfer = Transfer.new(Colour, flat_model())
    local floor = {1, 1, 1, 0.07, 0.07, 0.07}
    local _, _, _, err = transfer.fit(test_row(), 25, 0, 0, floor)
    local L = transfer.fit(test_row(), 25, 0, 0, floor)
    assert(err > 5 and L > 30, 'black paint still reflects 7%: L ' .. L)
    local _, _, _, free = transfer.fit(test_row(), 25, 0, 0, {1, 1, 1, 0, 0, 0})
    assert(free < Transfer.FIT_DONE, 'no floor: reached, dE ' .. free)
end)

check('v12: a measured pattern\'s texel is the desired color through its gain', function()
    local r, g, b = Recolor.pattern_texel({L = 54, a = 41, b = 15, gain = {0.5, 0.6, 0.7}}, Colour)
    local lr, lg, lb = Colour.lab_to_linear(54, 41, 15)
    for i, v in ipairs({{r, lr / 0.5}, {g, lg / 0.6}, {b, lb / 0.7}}) do
        assert(math.abs(v[1] - Colour.linear_to_srgb(v[2])) < 1e-12, 'channel ' .. i)
    end
    local pr, pg, pb = Recolor.pattern_texel({L = 54, a = 41, b = 15}, Colour)
    local er, eg, eb = Colour.lab_to_srgb(54, 41, 15)
    assert(pr == er and pg == eg and pb == eb, 'unmeasured: the desired color itself')
end)

check('a pattern texel keeps the desired hue where the gain would turn it, and a neutral stays neutral (2026-10-07)',
      function()
    -- the B-01 Tactical's yellow stripes (gain measured at their yellow) asked for the IX-VOIDWALKER's navy: per channel
    -- the texel turned grey-green (hue 167 degrees, the navy's -99) and showed grey-green; the gain's luminance scales
    -- the navy instead
    local gain = {0.694, 0.767, 1.188}
    local r, g, b = Recolor.pattern_texel({L = 24.1, a = -1.3, b = -7.9, gain = gain}, Colour)
    local luma = 0.2126 * gain[1] + 0.7152 * gain[2] + 0.0722 * gain[3]
    local lr, lg, lb = Colour.lab_to_linear(24.1, -1.3, -7.9)
    for i, v in ipairs({{r, lr}, {g, lg}, {b, lb}}) do
        assert(math.abs(v[1] - Colour.linear_to_srgb(v[2] / luma)) < 1e-12, 'navy channel ' .. i .. ' by the luminance')
    end
    local _, ta, tb = Colour.srgb_to_lab(r, g, b)
    local gap = math.abs(math.deg(math.atan2(tb, ta) - math.atan2(-7.9, -1.3)))
    assert(gap < 2, string.format('the navy hue kept: %.1f degrees apart', gap))
    -- a near-neutral goal (chroma < 5) takes no tint from the gain (the B-01 band's dark, gain of its royal blue)
    local nr, ng, nb = Recolor.pattern_texel({L = 21.6, a = 0.2, b = 0.2, gain = {1.315, 1.102, 0.968}}, Colour)
    local _, na, nb_ = Colour.srgb_to_lab(nr, ng, nb)
    assert(math.sqrt(na * na + nb_ * nb_) < 1, 'a neutral stays neutral')
    -- a goal near the gain's own hue goes through it per channel (the FS-23 Battle Master's stripes turned red, agreed
    -- 2026-10-05)
    local rr = Recolor.pattern_texel({L = 39.7, a = 58.9, b = 43.3, gain = {0.809, 0.847, 1.125}}, Colour)
    assert(math.abs(rr - Colour.linear_to_srgb(Colour.lab_to_linear(39.7, 58.9, 43.3) / 0.809)) < 1e-12,
           'the red per channel')
end)

check('a soft row\'s fit counts its whole gloss floor (2026-10-07: salmon cloth asked for a dark red)', function()
    -- the TG-8 Sharpshooter's cloth fitted to the UF-50 Bloodhound's red aimed at L 22 on its paint alone; its sheen
    -- (the floor) showed as well, L 29 on screen. A matte soft row (cloth: mode 1, no specular) reaches the goal with
    -- its whole floor counted; hard rows and glossy soft rows (specular 0.3: the UF-84 Doubt Killer's red trim, whose
    -- red reads red, agreed 2026-10-05) keep the hard rule (a colored paint's gloss reads as highlights).
    local model = flat_model()
    local transfer = Transfer.new(Colour, model)
    local cal = {1, 1, 1, 0.02, 0.02, 0.02}
    local soft, hard, glossy = test_row(), test_row(), test_row()
    soft[4], soft[33] = 1, 0 -- mode 1, column 8 x (specular) 0
    glossy[4], glossy[33] = 1, 0.3
    assert(Colour.is_soft(soft) and not Colour.is_soft(hard) and not Colour.is_soft(glossy), 'cloth only')
    local _, _, _, err = transfer.fit(soft, 30, 30, 18, cal)
    transfer.fit(hard, 30, 30, 18, cal)
    transfer.fit(glossy, 30, 30, 18, cal)
    local sL, sa, sb = model.look(soft, cal, true)
    local hL, gL = model.look(hard, cal, true), model.look(glossy, cal, true)
    assert(err < 1 and Colour.de2000(sL, sa, sb, 30, 30, 18) < 1, string.format('soft: reached with its floor, L %.1f '
           .. '(error %.2f)', sL, err))
    assert(hL > sL + 3, string.format('hard: the floor left out of its fit, it looks lighter: L %.1f', hL))
    assert(gL > sL + 3, string.format('glossy soft: the hard rule, it looks lighter: L %.1f', gL))
end)

-- v1.3 options. Rows as `measured` takes them, plus a mode per key (1 = cloth; default 0, hard); hoods: the kit's
-- hood rows {key -> true}; keep: Recolor Hoods off.
check('a colored trim on a neutral main part is an accent on both sides of 10% (no cliff)', function()
    -- an armor: dark plates (its main part, neutral) and a gold metal trim (chroma 26) at 9.9% or 10.5% of what shows;
    -- its helmet: dark, with a saturated yellow stripe (its accent). The 10.5% trim went dark before (the DP-53 Savior
    -- of the Free's gold braid with the B-01 Tactical, user 2026-10-07).
    local helmet = measured({{'h:0', 0.9, 25, 0, 0, 9000}, {'h:1', 0.1, 60, -10, 42, 1000}}, false)
    for _, px in ipairs({990, 1050}) do
        local armor = measured({{'a:0', 0.9, 33, 0, 0, 10000 - px}, {'a:1', 0.1, 49, 3, 26, px, true}}, true)
        local got = Matcher.plan(armor, helmet)['a:1']
        assert(got and got.kind == 'accent' and got.source == 'h:1', string.format('a %.1f%% trim takes the yellow: %s',
               px / 100, got and (got.kind .. ' ' .. got.source) or 'nothing'))
    end
    -- on a colored main part (olive) a 10.5% trim is a part like the others: it takes what the pairing gives
    local olive = measured({{'a:0', 0.9, 33, -8, 12, 8950}, {'a:1', 0.1, 49, 3, 26, 1050, true}}, true)
    local got = Matcher.plan(olive, helmet)['a:1']
    assert(got and got.kind == 'pair', 'a trim on a colored main part pairs: ' .. (got and got.kind or 'nothing'))
end)

check('a dark armor half undersuit takes the helmet\'s colors on both sides of 50% undersuit (no cliff)', function()
    -- one dark part (96% of what shows), a light metal buckle (2%), a yellow stripe (1.5%); the helmet cream (66%),
    -- navy (26%), black (8%), no saturated accent (the IX-VOIDWALKER). At 50.1% undersuit the dark part was structure
    -- and the armor did not change (a B-01 Tactical variant, user 2026-10-07); at 49.9% it took the cream.
    local voidwalker = measured({{'v:0', 0.66, 59, 1, 6, 6600}, {'v:1', 0.26, 24, -1, -8, 2600},
                                 {'v:2', 0.08, 19, 0, 0, 800}}, false)
    for _, under in ipairs({0.499, 0.501}) do
        local armor = measured({{'a:0', 0.92, 22, 0, 0, 9200, false, under}, {'a:1', 0.02, 60, -1, 0, 200, true},
                                {'a:2', 0.014, 79, 4, 68, 140}}, true)
        local plan = Matcher.plan(armor, voidwalker)
        local main, stripe = plan['a:0'], plan['a:2']
        assert(main and main.source == 'v:0', string.format('%.1f%% undersuit: the dark part takes the cream: %s',
               under * 100, main and main.source or 'nothing'))
        assert(stripe and stripe.kind == 'accent' and stripe.source == 'v:1', string.format(
               '%.1f%% undersuit: the stripe takes the navy, the second color: %s', under * 100,
               stripe and (stripe.kind .. ' ' .. stripe.source) or 'nothing'))
    end
end)

local function measured_with(rows, armor, modes, hoods, keep)
    local item = measured(rows, armor)
    local out, cals, kit = {}, {}, {luts = {}, rows = {}, patterns = {}}
    for i, row in ipairs(item.rows) do
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.L, copy.a, copy.b, copy.area, copy.under = row.mL, row.ma, row.mb, row.tex_area, rows[i][2] * (rows[i][8] or 0)
        copy.lens, copy.hood, copy.mL, copy.ma, copy.mb, copy.tex_area, copy.cal, copy.lin, copy.light = nil
        copy.mode = modes and modes[row.key] or 0
        out[i] = copy
        kit.luts[row.lut] = true
        if rows[i][6] > 0 then kit.rows[row.key] = {rows[i][6], row.light} end
        cals[row.key] = rows[i][9] or {1, 1, 1, 0, 0, 0}
    end
    local look = {kit = kit, row = function(lut, r) return cals[lut .. ':' .. r] end, hoods = hoods}
    return Matcher.item(out, armor, nil, look, keep)
end

check('Recolor Hoods off: the hood keeps its color, the mask and band match as before (RS-100, 2026-10-06)', function()
    -- the RS-100 Sanctioner: a black hood (75%) and a black mask (21%), one paint group; a gold metal brow band (3%).
    -- The CE-35 Trench Engineer: a black suit (65%, mostly undersuit), orange plates (28%), light trims.
    local rows = {{'h:0', 0.69, 15, 0, -1, 6900}, {'h:1', 0.06, 19, 0, 0, 600}, {'h:2', 0.15, 19, 1, 2, 1500},
                  {'h:3', 0.06, 19, 1, 2, 640}, {'h:4', 0.03, 57, 3, 27, 280, true}}
    local modes, hoods = {['h:0'] = 1, ['h:1'] = 1}, {['h:0'] = true, ['h:1'] = true}
    local trench = measured({{'c:0', 0.65, 21, 0, 0, 6500, false, 0.7}, {'c:1', 0.28, 51, 38, 59, 2800},
                             {'c:2', 0.05, 68, 1, 7, 500}}, true)
    local on = Matcher.plan(measured_with(rows, false, modes, hoods, false), trench)
    for _, key in ipairs({'h:0', 'h:1', 'h:2', 'h:3'}) do
        assert(on[key] and on[key].source == 'c:1', 'hoods on: the hood and the mask take the orange: ' .. key)
    end
    local kept = measured_with(rows, false, modes, hoods, true)
    assert(kept.groups[1].hood and kept.groups[1].share > 0.7 and not kept.groups[2].hood,
           'the hood is a group of its own and still counts in the helmet\'s paint')
    local off = Matcher.plan(kept, trench)
    assert(off['h:0'] == nil and off['h:1'] == nil, 'hoods off: the hood keeps its color')
    assert(off['h:2'].source == 'c:1' and off['h:3'].source == 'c:1', 'the mask takes the orange, the main color')
    assert(off['h:4'] and off['h:4'].kind == on['h:4'].kind and off['h:4'].source == on['h:4'].source,
           'the band takes what it took with the hood recolored')
    local plain = Matcher.plan(measured_with(rows, false, modes, nil, true), trench)
    assert(plain['h:0'] and plain['h:0'].source == 'c:1', 'a helmet without hood rows is unchanged by the option')
end)

check('Match Materials: big metal parts taking paint become it; small metal, cloth and metal colors stay', function()
    -- a metal helmet: a bare-metal shell (60%), a small metal bolt row (3%), a cloth strap (20%), a dark paint part
    local rows = {{'t:0', 0.6, 60, 2, 20, 6000, true}, {'t:1', 0.03, 30, 0, 0, 300, true},
                  {'t:2', 0.2, 25, 1, 3, 2000}, {'t:3', 0.17, 22, 0, 0, 1700}}
    local helmet = measured_with(rows, false, {['t:2'] = 1})
    local white = {0.8, 0.8, 0.8, 0.02, 0.02, 0.02}
    local armor = measured({{'a:0', 0.7, 75, 0, 3, 7000, false, 0, white}, {'a:1', 0.3, 24, 0, 0, 3000}}, true)
    local plain = Matcher.plan(helmet, armor)
    for key, goal in pairs(plain) do assert(goal.finish == nil, 'off: no finish on ' .. key) end
    local plan = Matcher.plan(helmet, armor, true)
    local shell = plan['t:0']
    assert(shell.source == 'a:0' and shell.finish == 'a:0' and shell.cal == white, 'the shell becomes the white paint')
    local g = armor.groups[1]
    assert(shell.L == g.L and shell.a == g.a and shell.b == g.b, 'aimed at the paint\'s own look, no metal offset')
    assert(plan['t:1'] and plan['t:1'].finish == nil, 'a 3% metal detail stays metal')
    assert(plan['t:2'] == nil or plan['t:2'].finish == nil, 'cloth keeps its material')
    assert(plan['t:3'] == nil or plan['t:3'].finish == nil, 'paint stays paint')
    -- metallic cloth (gold embroidery, the RE-1861 Parade Commander's trim: mode 1, metallic) keeps its material
    local embroidered = measured_with({{'t:0', 0.6, 60, 2, 20, 6000, true}, {'t:5', 0.25, 58, 3, 28, 2500, true},
                                       {'t:3', 0.15, 22, 0, 0, 1500}}, false, {['t:5'] = 1})
    local woven = Matcher.plan(embroidered, armor, true)
    assert(woven['t:0'].finish == 'a:0', 'the hard metal shell takes the paint')
    assert(woven['t:5'] and woven['t:5'].finish == nil, 'the metallic cloth stays as it is')
    -- a metal source color (v1.5, user decision 2026-10-14): a hard paint part taking it as it is turns into that
    -- metal, one coat of its paint; a darker part keeping a share of its own lightness stays paint, cloth never turns,
    -- and metal keeps its own material
    local gold = measured({{'m:0', 1.0, 60, 5, 40, 9000, true}}, true)
    for key, goal in pairs(Matcher.plan(helmet, gold, true)) do -- the metal shell leads: its darker paint stays paint
        assert(goal.finish == nil, 'metal source: ' .. key .. ' keeps its material')
    end
    local painted_shell = measured_with({{'t:0', 0.6, 60, 2, 20, 6000}, {'t:2', 0.2, 25, 1, 3, 2000},
                                         {'t:3', 0.2, 22, 0, 0, 2000}}, false, {['t:2'] = 1})
    local golden = Matcher.plan(painted_shell, gold, true)
    local plate = golden['t:0']
    assert(plate and plate.finish == 'm:0' and plate.coat and plate.cal == nil, 'metal source: the paint shell the metal')
    local rep = gold.groups[1].rep
    assert(plate.L == rep.mL and plate.a == rep.ma and plate.b == rep.mb, 'one coat of the metal\'s own paint')
    for _, key in ipairs({'t:2', 't:3'}) do
        assert(golden[key] == nil or golden[key].finish == nil, 'metal source: ' .. key .. ' keeps its material')
    end
    for key, goal in pairs(Matcher.plan(painted_shell, gold)) do assert(goal.finish == nil, 'option off: ' .. key) end
    -- an accent of any size: a 3% metal trim taking the armor's red trim becomes red paint
    local trimmed = measured_with({{'t:0', 0.8, 30, 0, 0, 8000}, {'t:1', 0.03, 55, 10, 45, 300, true}}, false)
    local red = measured({{'r:0', 0.9, 24, 0, 0, 9000}, {'r:1', 0.1, 45, 64, 46, 1000}}, true)
    local trim = Matcher.plan(trimmed, red, true)['t:1']
    assert(trim and trim.kind == 'accent' and trim.finish == 'r:1', 'a metal accent takes the red paint\'s finish')
    -- a pattern accent has no row to take a finish from: the metal trim keeps its material
    local YELLOW = {0.668, 0.625, 0.195}
    local striped = item({{'p:0', 1.0, 21, 0, 0}}, true,
                         {{pattern = 'bbbbbbbbbbbbbbbb', area = 0.02, r = YELLOW[1], g = YELLOW[2], b = YELLOW[3]}})
    local yellow = Matcher.plan(trimmed, striped, true)['t:1']
    assert(yellow and yellow.source == 'pattern:bbbbbbbbbbbbbbbb' and yellow.finish == nil, 'a pattern accent: no finish')
    -- a shell of two rows that look apart as metal (a bright top, a darker side): as paint both aim at the paint's own
    -- look (the difference came from the metal)
    local two = measured_with({{'t:0', 0.45, 60, 2, 20, 4500, true, 0, {1, 1, 1, 0, 0, 0}},
                               {'t:4', 0.15, 60, 2, 20, 1500, true, 0, {0.4, 0.4, 0.4, 0, 0, 0}},
                               {'t:3', 0.4, 22, 0, 0, 4000}}, false)
    assert(#two.groups == 2 and math.abs(two.groups[1].rows[1].L - two.groups[1].rows[2].L) > 5, 'two looks, one group')
    local both = Matcher.plan(two, armor, true)
    for _, key in ipairs({'t:0', 't:4'}) do
        assert(both[key].finish == 'a:0' and both[key].L == g.L, key .. ' aims at the paint\'s look: L ' .. both[key].L)
    end
    local kept = Matcher.plan(two, armor)
    assert(kept['t:0'].L ~= kept['t:4'].L, 'without the option each row keeps its offset')
end)

check('Match Materials: the finish copy takes metallic, specular and roughness; the rest stays the target\'s', function()
    local function lut(fill)
        local values = ffi.new('float[?]', 23 * 4 * 4)
        for i = 0, 23 * 4 * 4 - 1 do values[i] = fill(i) end
        return {values = values, width = 23, height = 4}
    end
    local target = {luts = {aaaaaaaaaaaaaaaa = lut(function(i) return i end)}}
    local source = {luts = {bbbbbbbbbbbbbbbb = lut(function(i) return -i end)}}
    local metallic = 2 * 92 + 27 -- source row 2, column 6 w
    source.luts.bbbbbbbbbbbbbbbb.values[metallic] = 1.7 -- clipped to 1
    local order = {}
    local transfer = {apply = function(values, width, row)
        order[#order + 1] = values[row * width * 4 + 27]
        return 0
    end}
    local plan = {['aaaaaaaaaaaaaaaa:1'] = {source = 'bbbbbbbbbbbbbbbb:2', kind = 'pair', L = 70, a = 0, b = 2,
                                            finish = 'bbbbbbbbbbbbbbbb:2'},
                  ['aaaaaaaaaaaaaaaa:3'] = {source = 'bbbbbbbbbbbbbbbb:2', kind = 'pair', L = 30, a = 0, b = 0}}
    local data = Recolor.build_luts(target, plan, transfer, function() end, source).aaaaaaaaaaaaaaaa.data
    local base = 92
    for c = 0, 22 do
        for ch = 0, 3 do
            local i, want = base + c * 4 + ch, base + c * 4 + ch
            if c == 6 and ch == 3 then want = 1 end
            if c == 7 then want = 0 end
            if c == 8 then want = -(2 * 92 + c * 4 + ch) end
            if c == 10 and ch == 0 then want = -(2 * 92 + 40) end
            assert(data[i] == want, string.format('row 1 column %d.%d: %s, expected %s', c, ch, data[i], want))
        end
    end
    for i = 3 * 92, 4 * 92 - 1 do assert(data[i] == i, 'row 3 (no finish) unchanged: ' .. i) end
    assert(#order == 2 and (order[1] == 1 or order[2] == 1), 'the fit runs on the row with its new finish')
    assert(target.luts.aaaaaaaaaaaaaaaa.values[base + 27] == base + 27, 'the vanilla LUT is untouched')
    local ok, why = pcall(Recolor.apply_finish, data, 23, 1, source, 'cccccccccccccccc:0')
    assert(not ok and tostring(why):find('not in the source analysis', 1, true), 'a missing source LUT is an error')
end)

-- src/variety.lua's roles on a plan crafted directly (v1.5, the mutation audit and independent review 1 2026-10-14). The
-- armor: grey plates (three hard rows, 93%) and a blue trim (7%), all planned to the helmet's dark grey: one color.
check('an armor left in one color: a source of one color leaves the plan as made (no shade "from nowhere": the user, '
      .. 'review 1); with a second color of its own a trim with no source accent becomes a tone 25 L from main, away '
      .. 'from the secondary (mirrored when out of range), and the darkest plates take the secondary', function()
    local Variety = require('variety')
    local armor = measured_with({{'a:0', 0.31, 45, 0, 0, 3100}, {'a:1', 0.31, 47, 0, 0, 3100},
                                 {'a:2', 0.31, 49, 0, 0, 3100}, {'a:3', 0.07, 40, 0, -40, 700}}, true)
    local function one_color()
        local plan = {}
        for _, key in ipairs({'a:0', 'a:1', 'a:2', 'a:3'}) do
            plan[key] = {source = 'h:0', kind = 'pair', L = 28, a = 0, b = 0}
        end
        return plan
    end
    local plan = one_color()
    local _, dominated = Variety.balance(plan, armor, measured_with({{'h:0', 1.0, 28, 0, 0, 9000}}, false))
    assert(dominated, 'one color: dominated')
    for key, m in pairs(plan) do
        assert(m.source == 'h:0' and m.L == 28 and not m.tone, 'a one-color source: as made, ' .. key)
    end
    -- the helmet: dark grey (L 28, 85%) and a light grey of its own (L 55, 15%): the secondary
    plan = one_color()
    Variety.balance(plan, armor, measured_with({{'h:0', 0.85, 28, 0, 0, 7650}, {'h:1', 0.15, 55, 0, 0, 1350}}, false))
    local trim = plan['a:3']
    assert(trim.tone == 'accent' and trim.L > 45, string.format('the trim a tone 25 L from main, away from the secondary '
           .. '(L 28 - 25 is out of range: L 53): %s L %.1f', tostring(trim.tone), trim.L))
    local darkest = plan['a:0']
    assert(darkest.source == 'h:1' and darkest.L > 50, string.format('the darkest plates the secondary (L 55): %s L %.1f',
           tostring(darkest.source), darkest.L))
end)

-- Review renders 2026-10-14: the B-01 Tactical against the Cowboy Hat as v1.4 had cached it (no rows) failed in
-- helmet_main ("attempt to index local 'top'"): Matcher.balance ran on a source with no colors.
check('an armor in one color against a source with no colors (a mod\'s helmet without a color table, as v1.4 read it) '
      .. 'keeps its own colors: no plan, no balance, no error', function()
    local Variety = require('variety')
    local armor = measured_with({{'a:0', 0.31, 45, 0, 0, 3100}, {'a:1', 0.31, 47, 0, 0, 3100},
                                 {'a:2', 0.31, 49, 0, 0, 3100}, {'a:3', 0.07, 40, 0, -40, 700}}, true)
    local empty = Matcher.item({}, false)
    local ok, plan = pcall(Matcher.plan, armor, empty, true)
    assert(ok, 'planned without an error: ' .. tostring(plan))
    assert(next(plan) == nil, 'nothing planned: the armor keeps its own colors')
    local _, dominated = Variety.balance({}, armor, empty)
    assert(dominated == false, 'not balanced: nothing to balance with')
end)

-- User 2026-10-15 (the CE-35 Trench Engineer on the SA-04 Combat Technician, "still bugged ... sorely stuck out"): its
-- orange covered 68% by its own key and 15% more as a band that took the helmet's accent (its orange) while paired with
-- its grey, over cells that cover 85% of the paint; it never reached 85% and the armor stayed one solid orange.
check('an armor\'s dominant color counts a band under the color it shows, over the paint its parts cover; two '
      .. 'close greys of other keys stay apart', function()
    local Variety = require('variety')
    local armor = measured_with({{'aaaaaaaaaaaaaaaa:0', 0.68, 23, 0, 0, 6800}, {'aaaaaaaaaaaaaaaa:1', 0.15, 11, 0, -5, 1500},
                                 {'aaaaaaaaaaaaaaaa:2', 0.02, 69, -1, 2, 200}}, true)
    armor.paint_area = armor.paint_area / 0.85 -- lights and lenses outside the cells: 15% of the paint
    local plan = {['aaaaaaaaaaaaaaaa:0'] = {source = 'orange', kind = 'pair', L = 42, a = 34, b = 51},
                  ['aaaaaaaaaaaaaaaa:1'] = {source = 'grey', kind = 'pair', L = 51, a = 38, b = 59, band = true,
                                            shows = 'orange'},
                  ['aaaaaaaaaaaaaaaa:2'] = {source = 'grey', kind = 'pair', L = 26, a = 0, b = 1}}
    local cells = Variety.cells(plan, armor)
    local by, total = {}, 0.0
    for _, c in ipairs(cells) do by[c.row.key], total = c, total + c.share end
    assert(by['aaaaaaaaaaaaaaaa:1'].key == 'orange', 'the band counts as the orange it shows')
    assert(total < 0.9, string.format('the cells cover %.3f of the paint', total))
    local key, share, _, distinct = Variety.dominance(cells)
    local orange = by['aaaaaaaaaaaaaaaa:0'].share + by['aaaaaaaaaaaaaaaa:1'].share
    assert(key == 'orange' and math.abs(share - orange / total) < 1e-9
           and math.abs(distinct - by['aaaaaaaaaaaaaaaa:2'].share / total) < 1e-9,
           string.format('%s: %.4f of the covered paint, %.4f apart', tostring(key), share, distinct))
    assert(share >= Variety.DOMINANT_SHARE and distinct < Variety.SECOND_MIN, 'one color')
    -- the SR-64 Cinderblock's two greys (L 19, L 39) on the SC-15 Drone Master (suit L 21, vest L 31): within APART of
    -- each other but two colors of the helmet, no one color to split by an invented shade (user: "clearly being
    -- dominated by a non-dominant color")
    local greys = {{key = 'dark', share = 0.70, L = 21, a = 0, b = 0}, {key = 'grey', share = 0.30, L = 31, a = 0, b = 0}}
    key, share = Variety.dominance(greys)
    assert(key == 'dark' and share < Variety.DOMINANT_SHARE, string.format('two greys: %.2f', share))
    -- a pattern the plan keeps in its own color counts when it reads apart (the I-09 Heatseeker's black pattern, 22.5%,
    -- under the CW-36 Winter Warrior's white; user: its published look "was better"), not when it is close
    local white = {{key = 'white', share = 0.704, L = 58, a = 0, b = 6}, {key = 'white', share = 0.071, L = 50, a = 0, b = 6}}
    local kept_black, kept_light = {{share = 0.225, L = 13, a = 1, b = 0}}, {{share = 0.225, L = 61, a = -3, b = 5}}
    key, share, _, distinct = Variety.dominance(white, kept_black)
    assert(math.abs(share - 0.775) < 1e-9 and distinct >= Variety.SECOND_MIN,
           string.format('a black pattern of its own: %.3f, %.3f apart', share, distinct))
    key, share = Variety.dominance(white, kept_light)
    assert(math.abs(share - 1.0) < 1e-9, string.format('a light pattern of its own: %.3f', share))
end)

check('Match Materials from a cape as the source: a tint row (its cape LUT, 16 columns) gives its material row\'s '
      .. 'finish, never columns of the cape LUT (Helmet and Armor Match Cape)', function()
    local mat, cape = ffi.new('float[?]', 23 * 3 * 4), ffi.new('float[?]', 16 * 3 * 4)
    for i = 0, 23 * 3 * 4 - 1 do mat[i] = 0.001 * i end
    for i = 0, 16 * 3 * 4 - 1 do cape[i] = -1 end
    local source = {luts = {mmmmmmmmmmmmmmmm = {values = mat, width = 23, height = 3},
                            cccccccccccccccc = {values = cape, width = 16, height = 3}},
                    tint_of = {cccccccccccccccc = 'mmmmmmmmmmmmmmmm'}}
    local data = ffi.new('float[?]', 23 * 4)
    Recolor.apply_finish(data, 23, 0, source, 'cccccccccccccccc:2')
    local s = 2 * 23 * 4
    assert(data[27] == math.min(math.max(mat[s + 27], 0), 1) and data[32] == mat[s + 32] and data[35] == mat[s + 35]
           and data[40] == mat[s + 40], 'the material row 2 finish: ' .. data[32])
end)

-- Independent review round 3 (2026-10-14, case 1): the B-22 Model Citizen's chrome (roughness 0.10) on the FS-37
-- Ravager's quilted chest read as a white blotch and sparkle.
check('Match Materials: a part that was paint taking a mirror metal finish is at least METAL_ON_PAINT_ROUGH rough '
      .. '(the game\'s median metal); a part that was metal keeps the source\'s roughness', function()
    local chrome = ffi.new('float[?]', 23 * 4)
    chrome[27], chrome[40] = 1.0, 0.10 -- column 6 w metallic, column 10 x roughness
    local source = {luts = {cccccccccccccccc = {values = chrome, width = 23, height = 1}}}
    local paint = ffi.new('float[?]', 23 * 4)
    paint[27], paint[40] = 0.0, 0.70
    Recolor.apply_finish(paint, 23, 0, source, 'cccccccccccccccc:0')
    assert(paint[27] == 1 and math.abs(paint[40] - Recolor.METAL_ON_PAINT_ROUGH) < 1e-6,
           string.format('paint turned metal: metallic %.2f roughness %.2f', paint[27], paint[40]))
    local metal = ffi.new('float[?]', 23 * 4)
    metal[27], metal[40] = 1.0, 0.40
    Recolor.apply_finish(metal, 23, 0, source, 'cccccccccccccccc:0')
    assert(math.abs(metal[40] - 0.10) < 1e-6, string.format('metal keeps the chrome: roughness %.2f', metal[40]))
end)

-- v1.5 (end-user report 2026-10-14, the Cowboy Hat mod): a mod's gear without a color table, its albedo read and
-- recolored (src/albedo.lua). The BC1 rules are written here apart from src/albedo.lua: endpoints expanded by bit
-- replication, 4-color thirds and 3-color halves rounded down, 3-color index 3 transparent.
local Albedo = require('albedo')

local function park_miller(seed)
    local s = seed
    return function(n)
        s = (s * 16807) % 2147483647
        return s % n
    end
end

local function expand565(e)
    local r, g, b = math.floor(e / 2048), math.floor(e / 32) % 64, e % 32
    return {r * 8 + math.floor(r / 4), g * 4 + math.floor(g / 16), b * 8 + math.floor(b / 4)}
end

-- One texel of endpoints e0, e1 at index i in the 4-color (four) or 3-color mode: r, g, b, a.
local function ref_texel(e0, e1, i, four)
    local c0, c1 = expand565(e0), expand565(e1)
    if i == 0 then return c0[1], c0[2], c0[3], 255 end
    if i == 1 then return c1[1], c1[2], c1[3], 255 end
    if not four and i == 3 then return 0, 0, 0, 0 end
    local out = {}
    for k = 1, 3 do
        if not four then
            out[k] = math.floor((c0[k] + c1[k]) / 2)
        elseif i == 2 then
            out[k] = math.floor((2 * c0[k] + c1[k]) / 3)
        else
            out[k] = math.floor((c0[k] + 2 * c1[k]) / 3)
        end
    end
    return out[1], out[2], out[3], 255
end

local function pack565(r, g, b)
    return math.floor(r * 31 / 255 + 0.5) * 2048 + math.floor(g * 63 / 255 + 0.5) * 32 + math.floor(b * 31 / 255 + 0.5)
end

local function put_block(p, o, c0, c1, idx)
    p[o], p[o + 1], p[o + 2], p[o + 3] = c0 % 256, math.floor(c0 / 256), c1 % 256, math.floor(c1 / 256)
    for k = 0, 3 do p[o + 4 + k] = math.floor(idx / 256 ^ k) % 256 end
end

local function get_block(p, o)
    return p[o] + p[o + 1] * 256, p[o + 2] + p[o + 3] * 256,
        p[o + 4] + p[o + 5] * 256 + p[o + 6] * 65536 + p[o + 7] * 16777216
end

local function random_blocks(count, step, rnd)
    local data = ffi.new('uint8_t[?]', count * step)
    for i = 0, count - 1 do
        local o = i * step
        if step == 16 then for k = 0, 7 do data[o + k] = rnd(256) end o = o + 8 end
        put_block(data, o, rnd(65536), rnd(65536), rnd(65536) * 65536 + rnd(65536))
    end
    return data
end

local function copy(data, size)
    local out = ffi.new('uint8_t[?]', size)
    ffi.copy(out, data, size)
    return out
end

check('albedo: a BC1 block decodes in its 4-color and 3-color modes; a BC3 color block is always 4-color', function()
    local p, out = ffi.new('uint8_t[8]'), ffi.new('uint8_t[64]')
    put_block(p, 0, 0xF800, 0x001F, 0xE4) -- red, blue; texels 0-3 take indices 0, 1, 2, 3
    Albedo.color_block(p, 0, out, true)
    local want = {{255, 0, 0, 255}, {0, 0, 255, 255}, {170, 0, 85, 255}, {85, 0, 170, 255}}
    for t = 0, 3 do
        for ch = 0, 3 do assert(out[4 * t + ch] == want[t + 1][ch + 1], 'four: texel ' .. t .. ' channel ' .. ch) end
    end
    put_block(p, 0, 0x001F, 0xF800, 0xE4) -- blue <= red: the 3-color mode
    Albedo.color_block(p, 0, out, true)
    want = {{0, 0, 255, 255}, {255, 0, 0, 255}, {127, 0, 127, 255}, {0, 0, 0, 0}}
    for t = 0, 3 do
        for ch = 0, 3 do assert(out[4 * t + ch] == want[t + 1][ch + 1], 'three: texel ' .. t .. ' channel ' .. ch) end
    end
    Albedo.color_block(p, 0, out, false) -- a BC3 color block: 4-color whatever the order
    assert(out[8] == 85 and out[10] == 170 and out[12] == 170 and out[14] == 85 and out[15] == 255, 'BC3 four')
end)

check('albedo: blocks rewritten under any endpoint map decode to the mapped endpoints in their own mode (order flips, '
      .. 'equal endpoints, transparency)', function()
    local maps = {
        reverse = function(e) return 65535 - e end,
        hashed = function(e) return (e * 40503 + 7919) % 65536 end,
        collapsed = function(e) return e - e % 4096 end, -- one block in 16 gets two equal endpoints
    }
    local out = ffi.new('uint8_t[64]')
    for name, map in pairs(maps) do
        for _, step in ipairs({8, 16}) do
            local count = 2048
            local data = random_blocks(count, step, park_miller(step * 7 + #name))
            local before = copy(data, count * step)
            Albedo.forget()
            Albedo.rewrite(data, 0, count, step, map)
            for i = 0, count - 1 do
                local co = i * step + (step == 16 and 8 or 0)
                local c0, c1, idx = get_block(before, co)
                local four = step == 16 or c0 > c1
                Albedo.color_block(data, co, out, step == 8)
                for t = 0, 15 do
                    local r, g, b, a = ref_texel(map(c0), map(c1), math.floor(idx / 4 ^ t) % 4, four)
                    assert(out[4 * t] == r and out[4 * t + 1] == g and out[4 * t + 2] == b and out[4 * t + 3] == a,
                           string.format('%s step %d block %d texel %d', name, step, i, t))
                end
                for k = 0, step - 9 do assert(data[i * step + k] == before[i * step + k], 'BC3 alpha block kept') end
            end
        end
    end
end)

-- A synthetic mod albedo (a hat): 512 x 512 BC1 or BC3, 10 mips, whose mip 1 (256 x 256, the one read) holds leather
-- (2,560 blocks), a dark band (1,024), a badge of the leather's color that is metal in the mra (256), with_green: 16
-- green blocks (0.41%: merged), and transparent blocks; mip 0 is all green (never read), the smaller mips black. The
-- mra: BC3, metal red where the badge is.
local LEATHER, BAND, GREEN = {104, 72, 40}, {30, 30, 35}, {0, 255, 0}
local function hat_texture(format, with_green)
    local step = Albedo.BC1[format] and 8 or 16
    local info = {format = format, width = 512, height = 512, mips = 10, mip_offsets = {}, layer_bytes = 0}
    for m = 0, 9 do
        info.mip_offsets[m] = info.layer_bytes
        local side = math.max(1, 512 / 2 ^ m)
        info.layer_bytes = info.layer_bytes + math.max(1, math.ceil(side / 4)) ^ 2 * step
    end
    info.total = info.layer_bytes
    local data = ffi.new('uint8_t[?]', info.layer_bytes)
    local mra_info = {format = 77, width = 512, height = 512, mips = 10, mip_offsets = {}, layer_bytes = 0}
    for m = 0, 9 do
        mra_info.mip_offsets[m] = mra_info.layer_bytes
        local side = math.max(1, 512 / 2 ^ m)
        mra_info.layer_bytes = mra_info.layer_bytes + math.max(1, math.ceil(side / 4)) ^ 2 * 16
    end
    local mra = ffi.new('uint8_t[?]', mra_info.layer_bytes)
    local rnd = park_miller(11)
    local co = step == 16 and 8 or 0
    local green = pack565(GREEN[1], GREEN[2], GREEN[3])
    for i = 0, 128 * 128 - 1 do put_block(data, i * step + co, green, green, 0) end
    local kinds = {}
    for i = 0, 64 * 64 - 1 do
        local row, col = math.floor(i / 64), i % 64
        local o = info.mip_offsets[1] + i * step + co
        local metal = false
        if row < 40 or (row >= 56 and row < 60) then
            local n = function() return rnd(9) - 4 end -- within one 4-4-4 bin of the leather
            local c0 = pack565(LEATHER[1] + n(), LEATHER[2] + n(), LEATHER[3] + n())
            local c1 = pack565(LEATHER[1] + n(), LEATHER[2] + n(), LEATHER[3] + n())
            if c0 < c1 then c0, c1 = c1, c0 end
            if c0 == c1 then c1 = c0 - 32 end -- one green step: the same bin
            put_block(data, o, c0, c1, rnd(65536) * 65536 + rnd(65536))
            metal = row >= 56
            kinds[i] = metal and 'badge' or 'leather'
        elseif row < 56 then
            local e = pack565(BAND[1], BAND[2], BAND[3])
            put_block(data, o, e, e - 32, rnd(65536) * 65536 + rnd(65536)) -- one 4-4-4 bin
            kinds[i] = 'band'
        elseif with_green and row == 60 and col < 16 then
            put_block(data, o, green, green - 1, 0)
            kinds[i] = 'green'
        else
            put_block(data, o, 0, 0xFFFF, 0xFFFFFFFF) -- 3-color, all transparent
            kinds[i] = 'clear'
        end
        local mo = mra_info.mip_offsets[1] + i * 16 + 8
        put_block(mra, mo, metal and 0xF800 or 0, metal and 0xF800 or 0, 0)
    end
    local function reader(buffer)
        return function(at, size, out, out_offset) ffi.copy(out + (out_offset or 0), buffer + at, size) end
    end
    local function texture(name)
        if name == 'albedo' then return info, reader(data) end
        if name == 'mra' then return mra_info, reader(mra) end
        return nil
    end
    return texture, data, info, kinds
end

local function hat_read(format, with_green)
    local texture = hat_texture(format, with_green)
    return Albedo.read({albedo = 'albedo', mra = 'mra'}, texture, Colour, function() end)
end

check('albedo: a mod albedo reads into clusters: its mip under 256, opaque texels only, a metal part apart from the '
      .. 'same color, a 0.41% color merged; the same clusters every read', function()
    local clean = hat_read(71, false)
    local L0, A0, B0 = Colour.srgb_to_lab(LEATHER[1] / 255, LEATHER[2] / 255, LEATHER[3] / 255)
    local c = clean.clusters[1]
    assert(#clean.clusters == 3 and math.sqrt((c.lab[1] - L0) ^ 2 + (c.lab[2] - A0) ^ 2 + (c.lab[3] - B0) ^ 2) < 3
           and math.abs(clean.clusters[1].share - 2 / 3) < 1e-9 and math.abs(clean.clusters[3].share - 1 / 15) < 1e-9,
           string.format('leather %.1f %.1f %.1f, %d clusters', c.lab[1], c.lab[2], c.lab[3], #clean.clusters))
    local a = hat_read(71, true)
    assert(a.format == 71 and a.width == 512 and a.mips == 10 and #a.clusters == 3, 'three clusters: ' .. #a.clusters)
    local opaque = 2560 + 1024 + 256 + 16
    local leather, band, badge = a.clusters[1], a.clusters[2], a.clusters[3]
    assert(leather.metal == 0 and band.metal == 0 and badge.metal == 1, 'the badge is the metal cluster')
    assert(math.abs(badge.lab[1] - L0) < 3, 'the badge has the leather color')
    assert(band.lab[1] < 15, 'the band is dark')
    local shares = {2560, 1024, 256}
    local total = 0
    for k, c in ipairs(a.clusters) do
        total = total + c.share
        assert(c.share >= shares[k] / opaque - 1e-9 and c.share <= (shares[k] + 16) / opaque + 1e-9,
               'share ' .. k .. ' ' .. c.share)
        assert(c.lab[2] > -20, 'no green cluster')
    end
    assert(math.abs(total - 1) < 1e-9, 'shares add up')
    local again = hat_read(71, true)
    for k, c in ipairs(a.clusters) do
        local d = again.clusters[k]
        assert(d.share == c.share and d.lab[1] == c.lab[1] and d.lab[2] == c.lab[2] and d.lab[3] == c.lab[3]
               and d.metal == c.metal, 'deterministic ' .. k)
    end
    local bc3 = hat_read(78, true) -- its color blocks; its alpha is no transparency (other data): the 'transparent'
    local metal = 0                -- blocks count, as their 4-color grey
    for _, k in ipairs(bc3.clusters) do metal = metal + (k.metal == 1 and 1 or 0) end
    assert(#bc3.clusters == 4 and metal == 1 and bc3.clusters[1].share >= 2560 / 4096 - 1e-9
           and bc3.clusters[1].share <= 2576 / 4096 + 1e-9,
           'a BC3 albedo: ' .. #bc3.clusters .. ' clusters, ' .. bc3.clusters[1].share)
end)

check('albedo: an unplanned albedo rewrites byte-exact (BC1 and BC3, every mip)', function()
    for _, format in ipairs({71, 77}) do
        local texture, data, info = hat_texture(format, true)
        local albedo = Albedo.read({albedo = 'albedo', mra = 'mra'}, texture, Colour, function() end)
        local before = copy(data, info.layer_bytes)
        local spec = Albedo.spec('albedo', albedo, {}, data, Colour, function() end)
        assert(spec.albedo and spec.bc1 == (format == 71) and spec.size == info.layer_bytes and spec.data == data,
               'spec fields')
        for i = 0, info.layer_bytes - 1 do assert(data[i] == before[i], 'byte ' .. i .. ' of format ' .. format) end
    end
end)

check('albedo: a planned cluster takes its goal on every mip, the spread of its texels kept; other clusters and '
      .. 'transparency stay', function()
    local texture, data, info, kinds = hat_texture(71, false)
    local albedo = Albedo.read({albedo = 'albedo', mra = 'mra'}, texture, Colour, function() end)
    local before = copy(data, info.layer_bytes)
    local goal = {L = 50, a = 35, b = 30} -- the plan's goal (a look) for the leather and its badge (one source color)
    Albedo.spec('albedo', albedo, {[1] = goal, [3] = goal}, data, Colour, function() end)
    goal = {} -- the albedo that looks like it (the study's typical response)
    goal.L, goal.a, goal.b = Albedo.unlook(Colour, 50, 35, 30)
    local out, was = ffi.new('uint8_t[64]'), ffi.new('uint8_t[64]')
    local worst, sum, n, c = {leather = 0, band = 0}, {0, 0, 0}, 0, albedo.clusters[1].lab
    for i = 0, 64 * 64 - 1 do
        local o = info.mip_offsets[1] + i * 8
        Albedo.color_block(data, o, out, true)
        Albedo.color_block(before, o, was, true)
        for t = 0, 15 do
            assert((out[4 * t + 3] == 0) == (was[4 * t + 3] == 0), 'transparency kept: block ' .. i)
            local L, A, B = Colour.srgb_to_lab(out[4 * t] / 255, out[4 * t + 1] / 255, out[4 * t + 2] / 255)
            local L0, A0, B0 = Colour.srgb_to_lab(was[4 * t] / 255, was[4 * t + 1] / 255, was[4 * t + 2] / 255)
            local kind = kinds[i]
            if kind == 'leather' or kind == 'badge' then -- its offset from the goal is its offset from the cluster
                local dL, da, db = (L - goal.L) - (L0 - c[1]), (A - goal.a) - (A0 - c[2]), (B - goal.b) - (B0 - c[3])
                worst.leather = math.max(worst.leather, math.sqrt(dL * dL + da * da + db * db))
                sum[1], sum[2], sum[3], n = sum[1] + L, sum[2] + A, sum[3] + B, n + 1
            elseif kind == 'band' then
                worst.band = math.max(worst.band, math.sqrt((L - L0) ^ 2 + (A - A0) ^ 2 + (B - B0) ^ 2))
            end
        end
    end
    local mean = math.sqrt((sum[1] / n - goal.L) ^ 2 + (sum[2] / n - goal.a) ^ 2 + (sum[3] / n - goal.b) ^ 2)
    assert(mean < 2 and worst.leather < 5, string.format('leather at the goal (%.2f), its spread kept (%.2f)', mean,
                                                        worst.leather))
    assert(worst.band < 0.5, string.format('band unchanged: %.2f', worst.band))
    for m = 2, 9 do -- the smaller mips (black, nearest the unplanned band) are kept
        local o = info.mip_offsets[m]
        assert(data[o] == before[o] and data[o + 2] == before[o + 2], 'mip ' .. m)
    end
    Albedo.color_block(data, info.mip_offsets[0], out, true) -- mip 0 (green, nearest the leather) moves with it
    Albedo.color_block(before, info.mip_offsets[0], was, true)
    assert(out[3] == 255 and (out[0] ~= was[0] or out[1] ~= was[1] or out[2] ~= was[2]), 'mip 0 rewritten too')
end)

check('albedo: a darkened cluster\'s parts keep their luminance ratio (a lightened one\'s keep their difference), and '
      .. 'a goal under NEUTRAL_C passes no hue offsets', function()
    local function lab_of(data, t) -- texel t of the block's decode
        local out = ffi.new('uint8_t[64]')
        Albedo.color_block(data, 0, out, true)
        return Colour.srgb_to_lab(out[4 * t] / 255, out[4 * t + 1] / 255, out[4 * t + 2] / 255)
    end
    local function block_of(c0, c1)
        local data = ffi.new('uint8_t[8]')
        put_block(data, 0, c0, c1, 0x4) -- texel 0 c0, texel 1 c1
        return data
    end
    local function one_cluster(L, a, b)
        return {format = 71, width = 4, height = 4, mips = 1, total = 8,
                clusters = {{share = 1, lab = {L, a, b}, lin = {Colour.lab_to_linear(L, a, b)}, metal = 0}}}
    end
    local function Y(L) return (Colour.lab_to_linear(L, 0, 0)) end
    -- greys: the cluster is c1 (L 49), darkened to L 20; c0 (L 64) keeps its ratio: L 28, where a difference gives 35
    local data = block_of(pack565(153, 153, 153), pack565(119, 119, 119))
    local L0, L1 = lab_of(data, 0), lab_of(data, 1)
    local base = Albedo.unlook(Colour, 20, 0, 0) -- the albedo that looks like the goal's L 20
    local y = Y(base) * Y(L0) / Y(L1)
    local want = Colour.linear_to_lab(y, y, y)
    Albedo.spec('albedo', one_cluster(L1, 0, 0), {[1] = {L = 20, a = 0, b = 0}}, data, Colour, function() end)
    local got = lab_of(data, 0)
    assert(math.abs(got - want) < 1.5 and math.abs(got - (base + L0 - L1)) > 4, string.format(
           'the lighter part darkened by the ratio: L %.1f, expected %.1f (a difference: %.1f)', got, want,
           base + L0 - L1))
    -- a reddish cluster (a 10) taking a near-neutral goal (a 3, under NEUTRAL_C): a redder part (a 40 more) gives no red
    local function byte(x) return math.floor(Colour.linear_to_srgb(x) * 255 + 0.5) end
    local function rgb565_of(L, a, b)
        local r, g, bl = Colour.lab_to_linear(L, a, b)
        return pack565(byte(r), byte(g), byte(bl))
    end
    data = block_of(rgb565_of(50, 50, 0), rgb565_of(50, 10, 0))
    local _, a0 = lab_of(data, 0)
    local cL, ca, cb = lab_of(data, 1)
    Albedo.spec('albedo', one_cluster(cL, ca, cb), {[1] = {L = 50, a = 3, b = 0}}, data, Colour, function() end)
    local _, a_got = lab_of(data, 0)
    local _, a_goal = Albedo.unlook(Colour, 50, 3, 0)
    local a_scaled = a_goal + (a0 - ca) * a_goal / ca
    assert(math.abs(a_got - a_goal) < 2.5 and math.abs(a_scaled - a_goal) > 8, string.format(
           'no hue offset toward a near-neutral goal: a %.1f, the goal\'s albedo a %.1f (scaled offsets: %.1f)',
           a_got, a_goal, a_scaled))
end)

check('albedo: only a mod\'s material of the character template with a BC1 or BC3 power-of-two albedo is read',
      function()
    local describe = function(name)
        if name == 'missing' then return nil end
        if name == 'broken' then error('unsupported texture format 2', 0) end
        if name == 'bc7' then return {format = 98, width = 512, height = 512} end
        if name == 'odd' then return {format = 71, width = 500, height = 512} end
        return {format = 71, width = 2048, height = 2048}
    end
    local mod, template = {file = '9ba626afa44a3aa3.patch_1'}, '7712ee7808e0ec50'
    local slots = function(albedo) return {[Albedo.SLOT_ALBEDO] = albedo, [Albedo.SLOT_MRA] = 'mra'} end
    local e = Albedo.eligible(mod, template, slots('hat'), describe)
    assert(e and e.albedo == 'hat' and e.mra == 'mra', 'the hat')
    local function refused(record, parent, textures, why)
        local ok, reason = Albedo.eligible(record, parent, textures, describe)
        assert(ok == nil and reason:find(why, 1, true), why .. ': ' .. tostring(reason))
    end
    refused({}, template, slots('hat'), 'not a mod')
    refused(mod, 'ffffffffffffffff', slots('hat'), 'shader template')
    refused(mod, template, {}, 'no albedo')
    refused(mod, template, slots('missing'), 'not found')
    refused(mod, template, slots('broken'), 'unsupported texture format 2')
    refused(mod, template, slots('bc7'), 'albedo format 98')
    refused(mod, template, slots('odd'), 'albedo size 500 x 512')
end)

check('albedo: a target\'s planned albedos become specs and one log line; a changed texture refuses', function()
    local texture, data, info = hat_texture(71)
    local albedo = Albedo.read({albedo = 'albedo', mra = 'mra'}, texture, Colour, function() end)
    local name = 'aaaaaaaaaaaaaaaa'
    local target = {albedos = {[name] = albedo}, kit = {archive = 'patch'}}
    local function chain(n, archive)
        assert(n == name and archive == 'patch')
        return copy(data, info.layer_bytes), info
    end
    local out = {}
    local line = Albedo.plan_specs(target, {[name .. ':0'] = {L = 50, a = 10, b = 10}}, out, chain, Colour,
                                   function() end)
    assert(out[name] and out[name].albedo and out[name].bc1 and out[name].width == 512 and out[name].mips == 10,
           'a spec for the planned albedo')
    assert(line == 'Mod texture ' .. name .. ' (a material without a color table): 3 colors read (67%, 27%, 7% metal); '
           .. '1 recolored.', line)
    out = {}
    line = Albedo.plan_specs(target, {}, out, chain, Colour, function() end)
    assert(next(out) == nil and line:find('0 recolored', 1, true), 'nothing planned: no texture made')
    local wrong = function() local i = {} for k, v in pairs(info) do i[k] = v end i.format = 77 return data, i end
    assert(not pcall(Albedo.plan_specs, target, {[name .. ':1'] = {L = 5, a = 0, b = 0}}, {}, wrong, Colour,
                     function() end), 'a texture other than the one analysed refuses')
end)

-- Recolor Weapons (v1.5) -------------------------------------------------------------------------------------------
local Weapons, Kits = require('weapons'), require('kits')

-- A copy span (src/weapons.lua COPY_SPAN from +0x78) with attachments and MaterialOverride rows written in.
local function copy_span(attachments, main_rows, kinds)
    local big = ffi.new('uint8_t[?]', Weapons.COPY_SPAN)
    local function name_at(o, name)
        local high, low = tonumber(name:sub(1, 8), 16), tonumber(name:sub(9, 16), 16)
        for k = 0, 3 do big[o + k] = math.floor(low / 256 ^ k) % 256 big[o + 4 + k] = math.floor(high / 256 ^ k) % 256 end
    end
    local function u32_at(o, v) for k = 0, 3 do big[o + k] = math.floor(v / 256 ^ k) % 256 end end
    local at = {0x78, 0x80, 0xA0, 0xC0}
    for role, name in pairs(attachments) do name_at(at[role] - 0x78, name) end
    local function rows(o, list)
        for r, row in ipairs(list) do
            u32_at(o + 40 * (r - 1), row[1])
            name_at(o + 40 * (r - 1) + 8, row[2])
            if row[3] then name_at(o + 40 * (r - 1) + 24, row[3]) end
        end
    end
    rows(200 - 0x78, main_rows)
    for e, kind in ipairs(kinds or {}) do
        u32_at(600 + 408 * (e - 1) - 0x78, kind[1])
        rows(600 + 408 * (e - 1) + 8 - 0x78, kind[2])
    end
    return big
end

check('weapons: a customization copy decodes to attachment names and per-slot paint (rows with a LUT or pattern of '
      .. 'their own; LUT 0 keeps the material\'s), by role; the kit lists the weapon unit and its attachments', function()
    local Z = '0000000000000000'
    local big = copy_span({[1] = '129e5fb1b13c2018', [3] = '756e3fdaca41cfca'},
        {{0x7c4a4a11, '72ba1e791ed0a166'}, {0x2b80449a, Z}, {0x1db4e620, Z, 'cf0cc31b981786c9'}},
        {{4, {{0x11111111, 'abcdabcdabcdabcd'}}}, {5, {{0x22222222, Z}}}})
    local w = {name = '968211c0033dce64', overrides = {}, attachments = {}}
    Weapons.decode_copy(w, big)
    assert(w.attachments[1] == '129e5fb1b13c2018' and w.attachments[3] == '756e3fdaca41cfca' and not w.attachments[2],
           'attachments by role')
    local main = w.overrides[0]
    assert(main.rows[0x7c4a4a11].lut == '72ba1e791ed0a166' and not main.rows[0x2b80449a], 'a LUT 0 row is none')
    assert(main.rows[0x1db4e620].lut == Z and main.rows[0x1db4e620].pattern == 'cf0cc31b981786c9', 'a pattern alone')
    assert(w.overrides[3] and w.overrides[3].rows[0x11111111].lut == 'abcdabcdabcdabcd', 'the muzzle (kind 4) by role')
    assert(w.overrides[2] and next(w.overrides[2].rows) == nil and w.overrides[2].text == '', 'magazines (kind 5) none')
    local kit = Weapons.kit(w, 'dbd9381f9ea9788f')
    assert(kit.kit_type == 'Weapon' and kit.archive == 'dbd9381f9ea9788f' and kit.id == 0x033dce64, 'the kit')
    assert(#kit.pieces == 3 and kit.pieces[1].path == w.name and kit.pieces[1].slot == 0
           and kit.pieces[2].path == '129e5fb1b13c2018' and kit.pieces[2].slot == 1
           and kit.pieces[3].path == '756e3fdaca41cfca' and kit.pieces[3].slot == 3, 'pieces by role')
    assert(kit.pieces[1].overrides_text and kit.pieces[1].overrides_text:find('72ba1e791ed0a166', 1, true)
           and kit.pieces[3].overrides_text == '11111111=abcdabcdabcdabcd/0000000000000000', 'paint in the signature')
    assert(Kits.signature(kit):find('72ba1e791ed0a166', 1, true), 'another paint is another record')
    assert(Kits.weight('Weapon', kit.pieces[1], 0) == 1.0 and Kits.weight('Weapon', kit.pieces[2], 0) < 0.5,
           'the weapon unit weighs most')
end)

check('weapons: an underbarrel (role 4) that is a weapon of its own takes the template\'s weapon classes where the '
      .. 'attachments\' do not apply (the AR-11 Arbitrator\'s under-barrel module, control check 2026-10-15); a muzzle '
      .. 'never does', function()
    local w = {name = 'a8a91eb54892b6b2', overrides = {},
               attachments = {[3] = '4851d75853622a47', [4] = 'b9c209b4f99b5335'}}
    local template = {id = 'helldiver', archive = 'd7353578fc8df474',
                      classes = {wb8b409a0 = '3d41e3dfac46deb9', a32090dd1 = 'b641b5115b3b40af'}}
    local kit = Weapons.kit(w, 'bf2250de0b17285c', template)
    local muzzle, under = kit.pieces[2], kit.pieces[3]
    assert(under.overrides[0xb8b409a0] and under.overrides[0xb8b409a0].lut == '3d41e3dfac46deb9',
           'the module\'s plasma class takes the weapon\'s')
    assert(under.overrides[0x32090dd1].lut == 'b641b5115b3b40af', 'its attachment class stays the attachments\'')
    assert(not muzzle.overrides[0xb8b409a0], 'a muzzle (a sub-unit) never takes the weapon\'s classes')
end)

check('weapons: the drawn-rows table parses per unit and material (triangles, 8 shares; missing rows 0)', function()
    local rows = Kits.weapon_rows({units = {['968211c0033dce64'] =
        'ddaa95e612f4468f:2940:0=0.9578,1=0.0422|7f112acd09a5e523:9687:0=0.1601,1=0.4128,5=0.1758'}})
    local triangles, shares = rows('968211c0033dce64', 'ddaa95e612f4468f')
    assert(triangles == 2940 and shares[1] == 0.9578 and shares[2] == 0.0422 and shares[3] == 0 and #shares == 8, 'rail')
    triangles, shares = rows('968211c0033dce64', '7f112acd09a5e523')
    assert(triangles == 9687 and shares[6] == 0.1758, 'body')
    assert(rows('968211c0033dce64', 'ffffffffffffffff') == nil and rows('0000000000000001', 'ddaa95e612f4468f') == nil,
           'unknown unit or material')
    local data = require('weapon_data')
    local liberator = Kits.weapon_rows(data)
    local t, s = liberator('968211c0033dce64', 'ddaa95e612f4468f')
    assert(t and s[1] > 0.9, 'the shipped table: the Liberator\'s rail draws row 0 (bare metal)')
end)

check('weapons: the inventory watch compares the three weapon slots and the slot in hand, not the throwable or '
      .. 'backpack fields; its binding check compares an exact texture object', function()
    local row = ffi.new('uint8_t[48]')
    local cell = ffi.new('uint8_t[8]')
    local memory = {read_into = function(p, size, out)
        local at = tonumber(ffi.cast('uintptr_t', p))
        if at == 0x10000 then ffi.copy(out, row, size) else ffi.copy(out, cell, size) end
        return true
    end}
    local watch = Weapons.watch(memory, {row = 0x10000})
    assert(watch.row_changed(), 'the first read counts as a change')
    assert(not watch.row_changed(), 'the same row')
    row[16] = 7 -- the throwable
    row[20] = 9 -- the backpack
    assert(not watch.row_changed(), 'a grenade or backpack changes nothing')
    row[28] = 1
    assert(watch.row_changed() and watch.held() == 1, 'the slot in hand')
    row[8] = 3
    assert(watch.row_changed(), 'a support weapon picked up')
    cell[0], cell[5] = 0x40, 0x12
    assert(watch.bound(0x20000, 0x40, 0x1200) and not watch.bound(0x20000, 0x41, 0x1200), 'the texture object, exact')
end)

check('weapons: a camo row\'s metallic bias (over 1.5) reads as its paint; bare metal (1.0) stays metal; only paint '
      .. 'rows are planned', function()
    local model = flat_model()
    local values = ffi.new('float[?]', 23 * 3 * 4)
    local function row(r, rgb, metallic)
        values[(r * 23) * 4], values[(r * 23) * 4 + 1], values[(r * 23) * 4 + 2] = rgb[1], rgb[2], rgb[3]
        values[(r * 23 + 6) * 4 + 3] = metallic
        values[(r * 23 + 21) * 4] = -1 -- no camo layer
    end
    row(0, {0.05, 0.05, 0.05}, -0.5) row(1, {0.4, 0.4, 0.4}, 1.0) row(2, {0.1, 0.2, 0.05}, 4.21)
    local lut, deps = {values = values, width = 23, height = 3}, {colour = model}
    assert(Kits.lut_row(lut, 2, deps).metal, 'the color model alone calls the camo row metal')
    local camo, steel, paint = Kits.lut_row(lut, 2, deps, true), Kits.lut_row(lut, 1, deps, true),
        Kits.lut_row(lut, 0, deps, true)
    assert(not camo.metal and steel.metal and not paint.metal, 'on a weapon: the bias row is paint, steel metal')
    assert(camo.L > Kits.lut_row(lut, 2, deps).L, 'its paint not darkened as metal')
    assert(values[(2 * 23 + 6) * 4 + 3] > 4.2, 'the LUT itself untouched')
    local w = Recolor.weapon_paint({{key = 'x:0', metal = false}, {key = 'x:1', metal = true}, {key = 'x:2', metal = false}})
    assert(#w == 2 and w[1].key == 'x:0' and w[2].key == 'x:2', 'bare metal rows are not planned')
end)

check('weapons: the preview\'s customization composed as the game does: the type\'s copy, then each id\'s patches of '
      .. 'type 271 in order (the span outside the copy left alone)', function()
    -- a tiny fake memory: entities D, the types' table, the deltas' table
    local space = {}
    local function region(base, size) local b = ffi.new('uint8_t[?]', size) space[#space + 1] = {base, size, b} return b end
    local function find(at, size)
        for _, r in ipairs(space) do if at >= r[1] and at + size <= r[1] + r[2] then return r[3] + (at - r[1]) end end
    end
    local function u32w(at, v) local p = find(at, 4) for k = 0, 3 do p[k] = math.floor(v / 256 ^ k) % 256 end end
    local function u64w(at, v) u32w(at, v % 4294967296) u32w(at + 4, math.floor(v / 4294967296)) end
    local function namew(at, name) u32w(at, tonumber(name:sub(9, 16), 16)) u32w(at + 4, tonumber(name:sub(1, 8), 16)) end
    local G, D, TYPES, DELTAS = 0x7000000000, 0x100000000, 0x200000000, 0x300000000
    region(G + 0x346BF98, 8) u64w(G + 0x346BF98, D)
    region(D + 0xF12CF0, 8) u64w(D + 0xF12CF0, TYPES)
    region(D + 0xF12E98, 8) u64w(D + 0xF12E98, DELTAS)
    local name, id = '968211c0033dce64', '9ebaa151ad0c4a59'
    local function mod(hex, n)
        local high, low = tonumber(hex:sub(1, 8), 16), tonumber(hex:sub(9, 16), 16)
        return ((high % n) * (4294967296 % n) + low % n) % n
    end
    region(TYPES, 382 * 16 + 0x17E0 + 4872 * 2)
    local slot = mod(name, 382)
    namew(TYPES + 16 * slot, name) u32w(TYPES + 16 * slot + 8, 1) -- index 1
    local base = TYPES + 0x17E0 + 4872
    namew(base + 0x78, '129e5fb1b13c2018') -- the type's optic
    u32w(base + 200, 0x7c4a4a11) -- its m_weapon row, LUT 0
    region(DELTAS, 72)
    local buckets, starts, ops, patches, data = 0x310000000, 0x320000000, 0x330000000, 0x340000000, 0x350000000
    u64w(DELTAS, buckets) u32w(DELTAS + 8, 8) u64w(DELTAS + 16, starts) u64w(DELTAS + 32, ops)
    u64w(DELTAS + 48, patches) u64w(DELTAS + 64, data)
    region(buckets, 8 * 16) namew(buckets + 16 * mod(id, 8), id) u32w(buckets + 16 * mod(id, 8) + 8, 0)
    region(starts, 8) u32w(starts, 2) u32w(starts + 4, 0) -- two ops from op 0
    region(ops, 24) u32w(ops, 99) u32w(ops + 12, 271) u32w(ops + 16, 0) u32w(ops + 20, 2) -- the first not type 271
    region(patches, 24)
    u32w(patches, 208) u32w(patches + 4, 8) u32w(patches + 8, 0) -- the m_weapon row's LUT
    u32w(patches + 12, 0x10) u32w(patches + 16, 8) u32w(patches + 20, 8) -- outside the span: left alone
    region(data, 16) namew(data, '72ba1e791ed0a166') namew(data + 8, 'ffffffffffffffff')
    local reader_buf = ffi.new('uint8_t[256]')
    local function read(at, size) local p = find(at, size) if not p then return nil end ffi.copy(reader_buf, p, size) return reader_buf end
    local function read_into(at, size, out) local p = find(at, size) if not p then return false end ffi.copy(out, p, size) return true end
    local w = {name = name, overrides = {}, attachments = {}}
    assert(Weapons.compose(read, read_into, G, w, {id}, ffi.new('uint8_t[?]', Weapons.COPY_SPAN)), 'composed')
    assert(w.attachments[1] == '129e5fb1b13c2018', 'the type\'s attachments')
    assert(w.overrides[0].rows[0x7c4a4a11].lut == '72ba1e791ed0a166', 'the id\'s paint patched in')
    local missing = {name = 'aaaaaaaaaaaaaaaa', overrides = {}, attachments = {}}
    local ok, why = Weapons.compose(read, read_into, G, missing, {}, ffi.new('uint8_t[?]', Weapons.COPY_SPAN))
    assert(not ok and why == 'weapon type not found', 'an unknown weapon')
end)

print('PASS test_units (' .. passed .. ' checks)')
