-- Match Your Colors: unit tests of the decoders and helpers that need no game files: LZ4 blocks, half floats,
-- the game's map probing, the idle watch, numpy summation order, CIEDE2000 reference pairs, the color transfer,
-- the matcher's trim and accent rules and LUT building.
-- Usage: luajit tests/test_units.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_units.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Slim, Texture, Avatar = require('slim'), require('texture'), require('avatar')
local Colour, Matcher, Recolor = require('colour'), require('matcher'), require('recolor')
local Transfer = require('transfer')
Matcher.use(Colour)
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
    assert(Matcher.npsum(a, 3) == ((1e16 + 1) - 1e16), 'sequential')
    local r = {a[1] + a[9], a[2] + a[10], a[3] + a[11], a[4] + a[12], a[5], a[6], a[7], a[8]}
    local expected = ((r[1] + r[2]) + (r[3] + r[4])) + ((r[5] + r[6]) + (r[7] + r[8])) + a[13]
    assert(Matcher.npsum(a, 13) == expected, 'pairwise')
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

check('the idle watch reports a change once, then only real changes; the body-copy slot in one read when asked',
      function()
    local units = ffi.new('uint8_t[120]')
    local copies = ffi.new('uint8_t[2116]') -- count (+64) and 16 entries of 132 bytes (+68)
    local readable, reads = true, {}
    local memory = {}
    function memory.read_into(address, size, out)
        local a = tonumber(ffi.cast('uintptr_t', address))
        reads[#reads + 1] = a
        if a == 0x1000 then ffi.copy(out, units, size) return true end
        if a == 0x2000 + 64 and size == 2116 and readable then ffi.copy(out, copies, size) return true end
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

-- An item from {key, area, L, a, b[, bare metal[, undergarment fraction]]} rows (no camo; paint unless the 6th is
-- true) and patterns {{pattern, area, r, g, b}} (texel 0 in sRGB).
local function item(rows, armor, patterns)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = {key = r[1], area = r[2], under = r[2] * (r[7] or 0), L = r[3], a = r[4], b = r[5],
                  metal = r[6] == true, camo = false, mode = 0, full = r[6] == true}
    end
    return Matcher.item(out, armor, patterns)
end

local Capes = require('capes')

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
    local plan = Matcher.plan(target, source)
    assert(plan['c:0'].source == 's:0' and plan['c:2'].source == 's:0', 'the plan: both the light')
    Matcher.cape_zones(plan, target, source, zones, nil)
    assert(plan['c:2'].source == 's:1' and plan['c:2'].kind == 'zone' and plan['c:2'].L == 20, 'the emblem: the dark')
    assert(plan['c:0'].source == 's:0', 'the cloth keeps its color')
    -- a zone still reading as planned stays
    local apart = item({{'s:0', 0.8, 75, 0, 0}, {'s:1', 0.2, 20, 0, 0}}, false)
    local reading = Matcher.item({row('c:0', 0, 0.9, 80), row('c:2', 2, 0.1, 30)}, false)
    plan = Matcher.plan(reading, apart)
    local before = plan['c:2'] and plan['c:2'].source
    Matcher.cape_zones(plan, reading, apart, zones, nil)
    assert(plan['c:2'] and plan['c:2'].source == before and plan['c:2'].kind ~= 'zone', 'a readable plan stays')
    -- a one-color source: no color reads, the emblem keeps its own (it reads against the new cloth)
    local one = item({{'s:0', 1.0, 60, 0, 0}}, false)
    local dark = Matcher.item({row('c:0', 0, 0.9, 62), row('c:2', 2, 0.1, 20)}, false)
    plan = Matcher.plan(dark, one)
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
    local plan = Matcher.plan(pillars, bloodhound)
    assert(plan['c:0'].source == 's:0' and plan['c:2'].source == 's:0', 'the plan: cloth and bars red')
    Matcher.cape_zones(plan, pillars, bloodhound, zones, nil)
    assert(plan['c:2'].source == 's:1' and plan['c:2'].kind == 'zone', 'the bars: black on the red')
    assert(plan['c:0'].source == 's:0', 'the cloth stays red')
    -- the Judgment Day: grey cloth, yellow marks; the cloth takes the black and the marks the red: they keep the red
    -- (the lightness rule put their yellow back)
    local judgment = Matcher.item({row('c:0', 0, 0.9, 26, 0, 0), row('c:2', 2, 0.1, 65, -9, 55)}, false)
    plan = Matcher.plan(judgment, bloodhound)
    local marks = plan['c:2'] and plan['c:2'].source
    assert(plan['c:0'].source == 's:1' and marks == 's:0', 'the plan: cloth black, marks red')
    Matcher.cape_zones(plan, judgment, bloodhound, zones, nil)
    assert(plan['c:2'] and plan['c:2'].source == 's:0', 'the marks stay red, not their own yellow')
    -- a source whose colors read neither way: the marks keep their own colors, as before
    local grey = item({{'s:0', 0.62, 27, 0, 0}, {'s:1', 0.38, 25, 1, 1}}, false)
    plan = Matcher.plan(judgment, grey)
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
    assert(plan['c:3'].source == 's:1' and plan['c:3'].kind == 'zone', 'the outline: brown, reading against the cloth')
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
    assert(a[1] + a[2] + a[3] + a[4] ~= 1.0 and Matcher.pysum(a, 4) == 1.0, 'compensated')
    assert(Matcher.pysum({}, 0) == 0 and Matcher.pysum({0.1}, 1) == 0.1 and Matcher.pysum({1, 2, 3}, 3) == 6,
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
    -- the other direction: paint takes the metal's color as it is (taking the light away turned paint black below
    -- L 23: the FS-37 Ravager helmet from the PH-202 Twigsnapper's dark bronze)
    local back = Matcher.plan(item({{'t:0', 1.0, 21, 0, 0}}, true), item({{'s:0', 1.0, 23, 0, 0, true}}, false))
    near(back['t:0'], 23, 'the paint row takes the metal color as it is')
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
    local transfer = {apply = function(values, width, row, L, a, b)
        calls[#calls + 1] = {row, L, a, b}
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
    -- a metal source color: nothing turns into metal, the metal shell keeps its own material
    local gold = measured({{'m:0', 1.0, 60, 5, 40, 9000, true}}, true)
    for key, goal in pairs(Matcher.plan(helmet, gold, true)) do assert(goal.finish == nil, 'metal source: ' .. key) end
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

print('PASS test_units (' .. passed .. ' checks)')
