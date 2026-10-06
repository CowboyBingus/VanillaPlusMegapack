-- Match Your Colors: the disk cache of kit analyses and shared samples (src/cache.lua): an exact round trip
-- (rows and pattern areas as %.17g, LUTs and pattern textures as raw float32, samples as bytes), files of another
-- build or data, damaged files, the entry cap, the kit checksum and the pauses between entries.
-- Usage: luajit tests/test_cache.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_cache.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Cache = require('cache')
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local BUILD = {exe_sha256 = string.rep('A', 64), game_sha256 = string.rep('B', 64)}
local HEADER = Cache.header(BUILD, '56:14545923')

local function kit(id, lut_fill)
    local pieces = {{path = 'aaaaaaaaaaaaaaaa', slot = 0, type = 0, body = 3, lut = '0000000000000000', tone = 0},
                    {path = 'bbbbbbbbbbbbbbbb', slot = 2, type = 1, body = 0, lut = 'cccccccccccccccc', tone = 2}}
    local values = ffi.new('float[?]', 23 * 8 * 4)
    for i = 0, 23 * 8 * 4 - 1 do values[i] = lut_fill + i / 3 end
    local analysis = {kit = {id = id, kit_type = 'Armor', archive = '0123456789abcdef', pieces = pieces}, body = 0,
                      rows = {{key = 'cccccccccccccccc:3', lut = 'cccccccccccccccc', row = 3, area = 0.1 / 3,
                               under = 1 / 7, L = 42.123456789012345, a = -3.25e-7, b = 17.5, metal = true,
                               camo = false, mode = 2.5, full = true, ar = 0.123456789012345, ag = 1 / 3,
                               ab = 2.5e-5}},
                      pieces = {{piece = pieces[1], skin = false, materials = {{}, {}}},
                                {piece = pieces[2], skin = true, materials = {{}}}},
                      luts = {cccccccccccccccc = {values = values, width = 23, height = 8},
                              dddddddddddddddd = {values = ffi.new('float[12]', {0.668, 0.625, 0.195, 0, 0, 0, 0, 1,
                                                                                0, 0, 0, 0.3}), width = 3, height = 1}},
                      patterns = {{pattern = 'dddddddddddddddd', area = 0.012345678901234567}}}
    return analysis
end

check('round trip: rows, pieces and LUT values come back exactly', function()
    local a = kit(0x0ade6719, 0.25)
    local key = Cache.key(a.kit, 0)
    local text = Cache.encode(HEADER, {[key] = a}, {key})
    local entries, order = Cache.decode(text, HEADER)
    assert(entries and order[1] == key, tostring(order))
    local b = entries[key]
    assert(b.kit.id == 0x0ade6719 and b.kit.kit_type == 'Armor' and b.kit.archive == '0123456789abcdef' and b.body == 0)
    local r, s = a.rows[1], b.rows[1]
    for _, f in ipairs({'key', 'lut', 'row', 'area', 'under', 'L', 'a', 'b', 'metal', 'camo', 'mode', 'full', 'ar', 'ag',
                        'ab'}) do
        assert(r[f] == s[f], 'row field ' .. f)
    end
    assert(#b.pieces == 2 and b.pieces[1].piece.slot == 0 and b.pieces[2].piece.type == 1 and b.pieces[2].skin
           and #b.pieces[1].materials == 2, 'pieces')
    local lut = b.luts.cccccccccccccccc
    assert(lut.width == 23 and lut.height == 8, 'LUT size')
    for i = 0, 23 * 8 * 4 - 1 do assert(lut.values[i] == a.luts.cccccccccccccccc.values[i], 'LUT value ' .. i) end
    assert(#b.patterns == 1 and b.patterns[1].pattern == 'dddddddddddddddd'
           and b.patterns[1].area == a.patterns[1].area, 'pattern and its area')
    local texture = b.luts.dddddddddddddddd
    assert(texture.width == 3 and texture.height == 1, 'pattern texture size')
    for i = 0, 11 do assert(texture.values[i] == a.luts.dddddddddddddddd.values[i], 'pattern value ' .. i) end
end)

check('the shared samples come back exactly (bytes / 255); without samples there is no block', function()
    local function layers(n, seed)
        local out = {}
        for l = 0, n - 1 do
            local values = ffi.new('double[2048]')
            for i = 0, 2047 do values[i] = ((i * 7 + l * 13 + seed) % 256) / 255 end
            out[l] = values
        end
        return out
    end
    local samples = {archive = '18235e0c9ec0e636', detail = layers(26, 1), detail_layers = 26, camo = layers(5, 2),
                     camo_layers = 5}
    local a = kit(3, 0)
    local key = Cache.key(a.kit, 0)
    local entries, order, got = Cache.decode(Cache.encode(HEADER, {[key] = a}, {key}, samples), HEADER)
    assert(entries and order[1] == key and entries[key] and got, 'entries and samples decoded')
    assert(got.archive == samples.archive and got.detail_layers == 26 and got.camo_layers == 5, 'samples header')
    for _, name in ipairs({'detail', 'camo'}) do
        for l = 0, samples[name .. '_layers'] - 1 do
            for i = 0, 2047 do assert(got[name][l][i] == samples[name][l][i], name .. ' value ' .. i) end
        end
    end
    local _, _, none = Cache.decode(Cache.encode(HEADER, {[key] = a}, {key}), HEADER)
    assert(none == nil, 'no samples block')
    local text = Cache.encode(HEADER, {}, {}, samples)
    assert(Cache.decode(text, HEADER) and not Cache.decode(text:sub(1, #text - 1), HEADER), 'truncated samples')
    assert(not Cache.decode(text:gsub(' 26 5 ', ' 26 4 ', 1), HEADER), 'sample count disagrees with the size')
end)

check('another build, other data or a damaged file is not used', function()
    local a = kit(1, 0)
    local key = Cache.key(a.kit, 0)
    local text = Cache.encode(HEADER, {[key] = a}, {key})
    assert(not Cache.decode(text, Cache.header(BUILD, '57:14545923')), 'other data')
    assert(not Cache.decode(text, Cache.header({exe_sha256 = 'C', game_sha256 = 'D'}, '56:14545923')), 'other build')
    assert(not Cache.decode(text:sub(1, #text - 100), HEADER), 'truncated LUT')
    assert(not Cache.decode(text:gsub('\nR ', '\nX ', 1), HEADER), 'unknown record')
    assert(not Cache.decode(text:gsub(' 0.1', ' nope', 1), HEADER), 'bad number')
    assert(not Cache.decode(nil, HEADER) and not Cache.decode('', HEADER), 'no file')
end)

check('the file keeps the most recently used entries, at most MAX_ENTRIES', function()
    local all, order = {}, {}
    for i = 1, Cache.MAX_ENTRIES + 5 do
        local a = kit(i, i)
        local key = Cache.key(a.kit, 0)
        all[key] = a
        order[#order + 1] = key
    end
    local entries, kept = Cache.decode(Cache.encode(HEADER, all, order), HEADER)
    assert(entries and #kept == Cache.MAX_ENTRIES and kept[1] == order[1], 'cap and order')
end)

check('encoding and decoding pause after each entry, inside a coroutine (the yield crosses the pcall)', function()
    local all, order = {}, {}
    for i = 1, 5 do
        local a = kit(i, i)
        local key = Cache.key(a.kit, 0)
        all[key] = a
        order[#order + 1] = key
    end
    local yields = 0
    local job = coroutine.wrap(function()
        local text = Cache.encode(HEADER, all, order, nil, coroutine.yield)
        local entries, kept = Cache.decode(text, HEADER, coroutine.yield)
        return entries and #kept
    end)
    local result = job()
    while result == nil do
        yields = yields + 1
        result = job()
    end
    assert(result == 5 and yields == 10, string.format('%s entries, %d pauses', tostring(result), yields))
    assert(#Cache.encode(HEADER, all, order) == #Cache.encode(HEADER, all, order, nil, function() end), 'same text')
end)

check('a changed piece list changes the key; the body is part of it', function()
    local a = kit(7, 0)
    local key = Cache.key(a.kit, 0)
    assert(Cache.key(a.kit, 1) ~= key, 'body')
    a.kit.pieces[2].lut = 'dddddddddddddddd'
    assert(Cache.key(a.kit, 0) ~= key, 'pieces')
end)

check('writes go through a temporary file; the text reads back', function()
    local path = root .. '/build/test-cache.tmpfile'
    assert(Cache.write(path, 'abc\n'))
    assert(Cache.read(path) == 'abc\n')
    assert(Cache.write(path, 'second\n') and Cache.read(path) == 'second\n', 'replaced')
    os.remove(path)
    assert(Cache.read(path) == nil)
end)

print('PASS test_cache (' .. passed .. ' checks)')
