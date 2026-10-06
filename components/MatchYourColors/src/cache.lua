-- Match Your Colors: the analyses of kits seen before, kept on disk, so a later session recolors as soon as the
-- Helldiver appears instead of reading the game files again (the first analysis of a helmet and armor is about
-- 90 ms of work spread over about 50 frames).
--
-- One file, MatchYourColors.cache, beside the mod's log. Its first line names the format version, the game
-- build (game.dll and EXE hashes) and the game data (the slim index's chunk count and size); any difference, or
-- anything the parser does not expect, discards the whole file and the analyses are made again. Next come the
-- shared tiler samples the color model and the color transfer need (so a cached session reads no game file):
--
--   S <archive> <detail layers> <camo layers> <bytes>, a newline, then 512 RGBA texels per layer as bytes
--
-- Each entry is one kit for one body type, keyed by its id, archive and a checksum of its piece list as the game
-- lists it:
--
--   K <key> <kit id> <kit type> <archive> <body> <rows> <pieces> <luts> <patterns>
--   R <key> <lut> <row> <area> <under> <L> <a> <b> <metal> <camo> <mode> <full> <albedo r> <g> <b>
--     (numbers as %.17g: exact; format 5 added the row's mean albedo, matcher v12)
--   P <slot> <type> <body> <skin> <materials>
--   T <pattern texture> <area>
--   L <lut> <width> <height> <bytes>, a newline, then the LUT's (or pattern texture's) float32 values as raw bytes
--
-- The file is read inside the session's first recolor job and written by the addon's save job (src/addon.lua),
-- both pausing between entries, never on an idle frame; it is written through a temporary file and a rename, so
-- an interrupted save leaves the previous file. Nothing in it is executed.
local ffi = require('ffi')

local Cache = {}

Cache.FILE = 'MatchYourColors.cache'
Cache.VERSION = 5
Cache.MAX_ENTRIES = 64
local NUMBER = '%.17g'
local TEXELS = 512 -- per sample layer (Kits.shared_samples)
local LAYER_BYTES = TEXELS * 4

-- A short checksum of a kit's piece list (Adler-32 of its fields), so a changed kit is analysed again.
function Cache.pieces_sum(kit)
    local a, b = 1, 0
    for _, piece in ipairs(kit.pieces) do
        local text = table.concat({piece.path, piece.slot, piece.type, piece.body, piece.lut, piece.tone}, ',')
        for i = 1, #text do
            a = (a + text:byte(i)) % 65521
            b = (b + a) % 65521
        end
    end
    return string.format('%08x', b * 65536 + a)
end

-- The key of a kit's analysis for one body type.
function Cache.key(kit, body)
    return string.format('%08x:%d:%s:%s', kit.id, body, kit.archive, Cache.pieces_sum(kit))
end

-- The cache file's first line for a build and data signature.
function Cache.header(build, data)
    return string.format('MYCCACHE %d %s %s %s', Cache.VERSION, build.exe_sha256, build.game_sha256, data)
end

local function number(text)
    local value = tonumber(text)
    if value == nil then error('cache: bad number', 0) end
    return value
end

-- One entry's text and binary blocks, appended to parts.
local function encode_entry(parts, key, analysis)
    local luts = {}
    for name, lut in pairs(analysis.luts) do luts[#luts + 1] = {name, lut} end
    table.sort(luts, function(x, y) return x[1] < y[1] end)
    local kit = analysis.kit
    local patterns = analysis.patterns or {}
    parts[#parts + 1] = string.format('K %s %08x %s %s %d %d %d %d %d\n', key, kit.id, kit.kit_type, kit.archive,
        analysis.body, #analysis.rows, #analysis.pieces, #luts, #patterns)
    for _, r in ipairs(analysis.rows) do
        parts[#parts + 1] = string.format('R %s %s %d ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER
            .. ' ' .. NUMBER .. ' %d %d ' .. NUMBER .. ' %d ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER .. '\n', r.key,
            r.lut, r.row, r.area, r.under, r.L, r.a, r.b, r.metal and 1 or 0, r.camo and 1 or 0, r.mode,
            r.full and 1 or 0, r.ar, r.ag, r.ab)
    end
    for _, entry in ipairs(analysis.pieces) do
        local p = entry.piece
        parts[#parts + 1] = string.format('P %d %d %d %d %d\n', p.slot, p.type, p.body, entry.skin and 1 or 0,
            #entry.materials)
    end
    for _, t in ipairs(patterns) do
        parts[#parts + 1] = string.format('T %s ' .. NUMBER .. '\n', t.pattern, t.area)
    end
    for _, item in ipairs(luts) do
        local lut = item[2]
        local size = lut.width * lut.height * 16
        parts[#parts + 1] = string.format('L %s %d %d %d\n', item[1], lut.width, lut.height, size)
        parts[#parts + 1] = ffi.string(lut.values, size)
    end
end

-- The samples block: values are channel bytes / 255 (src/texture.lua), so the bytes restore them exactly.
local function encode_samples(parts, samples)
    local bytes = ffi.new('uint8_t[?]', (samples.detail_layers + samples.camo_layers) * LAYER_BYTES)
    local at = 0
    for _, name in ipairs({'detail', 'camo'}) do
        for l = 0, samples[name .. '_layers'] - 1 do
            local values = samples[name][l]
            for i = 0, LAYER_BYTES - 1 do bytes[at + i] = math.floor(values[i] * 255 + 0.5) end
            at = at + LAYER_BYTES
        end
    end
    parts[#parts + 1] = string.format('S %s %d %d %d\n', samples.archive, samples.detail_layers, samples.camo_layers, at)
    parts[#parts + 1] = ffi.string(bytes, at)
end

-- The whole file for analyses {key -> analysis} (at most MAX_ENTRIES, most recently used first: order) and the
-- shared samples (none: no block). yield (optional) is called after each entry.
function Cache.encode(header, analyses, order, samples, yield)
    local parts = {header, '\n'}
    if samples then encode_samples(parts, samples) end
    local written = 0
    for _, key in ipairs(order) do
        if analyses[key] and written < Cache.MAX_ENTRIES then
            encode_entry(parts, key, analyses[key])
            written = written + 1
            if yield then yield() end
        end
    end
    return table.concat(parts)
end

-- A line starting at position `at` of text: its fields (split on spaces) and the position after it.
local function line_at(text, at)
    local stop = text:find('\n', at, true)
    if not stop then error('cache: truncated', 0) end
    local fields = {}
    for field in text:sub(at, stop - 1):gmatch('%S+') do fields[#fields + 1] = field end
    return fields, stop + 1
end

-- `count` R lines from `at` into analysis.rows; the position after them.
local function decode_rows(text, at, count, analysis)
    for i = 1, count do
        local r
        r, at = line_at(text, at)
        if r[1] ~= 'R' or #r ~= 16 then error('cache: bad row', 0) end
        analysis.rows[i] = {key = r[2], lut = r[3], row = number(r[4]), area = number(r[5]), under = number(r[6]),
                            L = number(r[7]), a = number(r[8]), b = number(r[9]), metal = r[10] == '1',
                            camo = r[11] == '1', mode = number(r[12]), full = r[13] == '1', ar = number(r[14]),
                            ag = number(r[15]), ab = number(r[16])}
    end
    return at
end

-- `count` P lines from `at` into analysis.pieces; the position after them.
local function decode_pieces(text, at, count, analysis)
    for i = 1, count do
        local p
        p, at = line_at(text, at)
        if p[1] ~= 'P' or #p ~= 6 then error('cache: bad piece', 0) end
        local materials = {}
        for m = 1, number(p[6]) do materials[m] = true end
        analysis.pieces[i] = {piece = {slot = number(p[2]), type = number(p[3]), body = number(p[4])},
                              skin = p[5] == '1', materials = materials}
    end
    return at
end

-- `count` T lines from `at` into analysis.patterns; the position after them.
local function decode_patterns(text, at, count, analysis)
    for i = 1, count do
        local t
        t, at = line_at(text, at)
        if t[1] ~= 'T' or #t ~= 3 then error('cache: bad pattern', 0) end
        analysis.patterns[i] = {pattern = t[2], area = number(t[3])}
    end
    return at
end

-- `count` L blocks from `at` into analysis.luts (values copied from the raw bytes); the position after them.
local function decode_luts(text, at, count, analysis, bytes)
    for _ = 1, count do
        local l
        l, at = line_at(text, at)
        if l[1] ~= 'L' or #l ~= 5 then error('cache: bad LUT', 0) end
        local width, height, size = number(l[3]), number(l[4]), number(l[5])
        if size ~= width * height * 16 or size <= 0 or at + size - 1 > #text then error('cache: bad LUT size', 0) end
        local values = ffi.new('float[?]', width * height * 4)
        ffi.copy(values, bytes + at - 1, size)
        analysis.luts[l[2]] = {values = values, width = width, height = height}
        at = at + size
    end
    return at
end

-- The samples block starting at `at`: the samples and the position after it.
local function decode_samples(text, at, bytes)
    local f
    f, at = line_at(text, at)
    if #f ~= 5 then error('cache: bad samples', 0) end
    local detail_layers, camo_layers, size = number(f[3]), number(f[4]), number(f[5])
    if detail_layers < 1 or camo_layers < 1 or size ~= (detail_layers + camo_layers) * LAYER_BYTES
        or at + size - 1 > #text then
        error('cache: bad samples size', 0)
    end
    local samples = {archive = f[2], detail = {}, camo = {}, detail_layers = detail_layers, camo_layers = camo_layers}
    for _, name in ipairs({'detail', 'camo'}) do
        for l = 0, samples[name .. '_layers'] - 1 do
            local values = ffi.new('double[?]', LAYER_BYTES)
            for i = 0, LAYER_BYTES - 1 do values[i] = bytes[at - 1 + i] / 255 end
            samples[name][l] = values
            at = at + LAYER_BYTES
        end
    end
    return samples, at
end

-- One entry starting at `at`: its key, the analysis and the position after it.
local function decode_entry(text, at, bytes)
    local f
    f, at = line_at(text, at)
    if f[1] ~= 'K' or #f ~= 10 then error('cache: bad entry', 0) end
    local analysis = {kit = {id = tonumber(f[3], 16), kit_type = f[4], archive = f[5]}, body = number(f[6]),
                      rows = {}, pieces = {}, luts = {}, patterns = {}, cached = true}
    at = decode_rows(text, at, number(f[7]), analysis)
    at = decode_pieces(text, at, number(f[8]), analysis)
    at = decode_patterns(text, at, number(f[10]), analysis)
    at = decode_luts(text, at, number(f[9]), analysis, bytes)
    return f[2], analysis, at
end

-- The analyses in a cache file's text: {key -> analysis}, their order and the shared samples (nil without the
-- block), or nil and why (another format, build or data, or a damaged file). yield (optional) is called after each
-- entry (inside a job's coroutine; LuaJIT yields across the pcall).
function Cache.decode(text, header, yield)
    if type(text) ~= 'string' or text:sub(1, #header + 1) ~= header .. '\n' then
        return nil, 'built for another version, game build or data'
    end
    local bytes = ffi.cast('const uint8_t *', text)
    local entries, order, samples = {}, {}, nil
    local ok, why = pcall(function()
        local at = #header + 2
        if text:sub(at, at + 1) == 'S ' then samples, at = decode_samples(text, at, bytes) end
        while at <= #text do
            local key, analysis
            key, analysis, at = decode_entry(text, at, bytes)
            entries[key] = analysis
            order[#order + 1] = key
            if yield then yield() end
        end
    end)
    if not ok then return nil, tostring(why) end
    return entries, order, samples
end

-- The cache file's path in the mod's log folder (the loader's, else %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs).
function Cache.path(loader)
    local directory = type(loader) == 'table' and loader.log_directory
    if type(directory) ~= 'string' or directory == '' then
        local local_app_data = os.getenv('LOCALAPPDATA')
        if not local_app_data then return nil end
        directory = local_app_data .. '/CowboyBingus/Helldivers2/Logs'
    end
    return directory .. '/' .. Cache.FILE
end

-- The file's text, or nil.
function Cache.read(path)
    local file = path and io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end

-- Writes text through <path>.tmp and a rename; true, or false and why (the previous file stays).
function Cache.write(path, text)
    local temp = path .. '.tmp'
    local file, reason = io.open(temp, 'wb')
    if not file then return false, reason end
    local written, write_error = file:write(text)
    local closed, close_error = file:close()
    if not (written and closed) then
        os.remove(temp)
        return false, write_error or close_error
    end
    os.remove(path)
    local moved, rename_error = os.rename(temp, path)
    if not moved then
        os.remove(temp)
        return false, rename_error
    end
    return true
end

-- Everything here runs inside a job, a few times per session: interpreted.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Cache.pieces_sum, Cache.key, Cache.header, number, encode_entry, encode_samples, Cache.encode,
                         line_at, decode_rows, decode_pieces, decode_patterns, decode_luts, decode_samples,
                         decode_entry, Cache.decode,
                         Cache.path, Cache.read, Cache.write}) do
        jit.off(fn, true)
    end
end

return Cache
