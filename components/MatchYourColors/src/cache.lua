-- Match Your Colors: the analyses of kits seen before, kept on disk, so a later session recolors as soon as the
-- Helldiver appears instead of reading the game files again (the first analysis of a helmet and armor is about
-- 90 ms of work spread over about 50 frames).
--
-- One file, MatchYourColors.cache, beside the mod's log. Its first line names the format version, the game
-- build (game.dll and EXE hashes) and the game data (the slim index's chunk count and size, and the signature of the
-- installed mods' patches, src/patches.lua); any difference, or
-- anything the parser does not expect, discards the whole file and the analyses are made again. Next come the
-- shared tiler samples the color model and the color transfer need (so a cached session reads no game file):
--
--   S <archive> <detail layers> <camo layers> <bytes>, a newline, then 512 RGBA texels per layer as bytes
--
-- Each entry is one kit for one body type, keyed by its id, archive and a checksum of its piece list as the game
-- lists it:
--
--   K <key> <kit id> <kit type> <archive> <body> <rows> <pieces> <luts> <patterns> <geometry patched> <changed rows>
--     <patched resources> <tint LUTs> <zone lines> <emblem-sheet layers (a cape's, src/capes.lua)>
--   R <key> <lut> <row> <area> <under> <L> <a> <b> <metal> <camo> <mode> <full> <albedo r> <g> <b> <emissive>
--     (numbers as %.17g: exact; format 5 added the row's mean albedo, matcher v12; format 6 its emissive intensity,
--     column 13 x, and a data signature naming the installed mods' patches, src/patches.lua)
--   V <row key> <finish changed> <has original> <L> <a> <b> <albedo r> <g> <b>: a mod's LUT row that differs from the
--     archived one, and the archived row's model color and albedo (format 7, src/kits.lua mark_patched)
--   P <slot> <type> <body> <skin> <materials>
--   T <pattern texture> <area>
--   L <lut> <width> <height> <bytes>, a newline, then the LUT's (or pattern texture's) float32 values as raw bytes
--   D <archive> <resource> <type> <hash>: a patched resource the analysis read and its content hash (format 7,
--     src/patches.lua content_hash; the entry is made again when one differs)
--   C <cape LUT> <material LUT>: a cape's tint rows are rows of its cape LUT recoloring that material LUT's rows
--     (format 8, src/capes.lua; its cape LUT is among the L blocks)
--   Z <zone> <row> <cells per tint bin, Capes.ZONE_BINS numbers>: a cape zone's border cells of one row (format 8,
--     src/capes.lua zones)
--
-- The file is read inside the session's first recolor job and written by the addon's save job (src/addon.lua),
-- both pausing between entries, never on an idle frame; it is written through a temporary file and a rename, so
-- an interrupted save leaves the previous file. Nothing in it is executed.
local ffi = require('ffi')

local Cache = {}

Cache.FILE = 'MatchYourColors.cache'
Cache.VERSION = 9
Cache.MAX_ENTRIES = 64
local NUMBER = '%.17g'
local TEXELS = 512 -- per sample layer (Kits.shared_samples)
local LAYER_BYTES = TEXELS * 4

-- A short checksum of a kit's piece list (Adler-32 of its fields), so a changed kit is analysed again.
function Cache.pieces_sum(kit)
    local a, b = 1, 0
    for _, piece in ipairs(kit.pieces) do
        local text = table.concat({piece.path, piece.slot, piece.type, piece.body, piece.lut, piece.tone}, ',')
            .. (piece.fields and (',' .. piece.fields) or '') -- a cape's scalar fields
            .. (piece.cape_lut and (',' .. piece.cape_lut .. ',' .. (piece.gradient or '') .. ','
                .. (piece.decal or '')) or '') -- its tint and emblems
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

-- The R lines of an entry's rows, and the V lines of those a mod's LUT changed (src/kits.lua mark_patched).
local function encode_rows(parts, rows, changed)
    for _, r in ipairs(rows) do
        parts[#parts + 1] = string.format('R %s %s %d ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER
            .. ' ' .. NUMBER .. ' %d %d ' .. NUMBER .. ' %d ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER .. ' '
            .. NUMBER .. '\n', r.key, r.lut, r.row, r.area, r.under, r.L, r.a, r.b, r.metal and 1 or 0,
            r.camo and 1 or 0, r.mode, r.full and 1 or 0, r.ar, r.ag, r.ab, r.emissive or 0)
    end
    for _, r in ipairs(changed) do
        local v = r.vanilla or {L = 0, a = 0, b = 0, ar = 0, ag = 0, ab = 0}
        parts[#parts + 1] = string.format('V %s %d %d ' .. string.rep(NUMBER, 6, ' ') .. '\n', r.key,
            r.finish_changed and 1 or 0, r.vanilla and 1 or 0, v.L, v.a, v.b, v.ar, v.ag, v.ab)
    end
end

-- The rows a mod's LUT changed.
local function changed_rows(analysis)
    local changed = {}
    for _, r in ipairs(analysis.rows) do
        if r.finish_changed ~= nil then changed[#changed + 1] = r end
    end
    return changed
end

-- The C lines of a cape's tint LUTs ({[cape LUT] = material LUT}), in name order.
local function tint_lines(tint_of)
    local lines = {}
    for cape_lut, material in pairs(tint_of or {}) do lines[#lines + 1] = string.format('C %s %s\n', cape_lut, material) end
    table.sort(lines)
    return lines
end

-- The Z lines of a cape's zones ({[zone] = {[row] = {[bin] = cells}}}, src/capes.lua), zones and rows in order.
local function zone_lines(zones)
    local lines = {}
    for z = 0, 4 do
        for q = 0, 4 do
            local counts = zones and zones[z] and zones[z][q]
            if counts then
                local text = {}
                for k = 0, #counts do text[k + 1] = string.format('%d', counts[k]) end
                lines[#lines + 1] = string.format('Z %d %d %s\n', z, q, table.concat(text, ' '))
            end
        end
    end
    return lines
end

-- The E lines of a cape's emblems (src/capes.lua emblems), in order: row, layer, own color, cells, sheet rect (-1
-- when none), sheet name, size, format and mips, then the cloth under it (one row and its bins).
local function emblem_lines(emblems)
    local lines = {}
    for _, e in ipairs(emblems or {}) do
        local q, counts = next(e.around)
        local bins = {}
        for k = 0, #counts do bins[k + 1] = string.format('%d', counts[k]) end
        local r = e.rect or {-1, -1, -1, -1}
        lines[#lines + 1] = string.format('E %d %d ' .. NUMBER .. ' ' .. NUMBER .. ' ' .. NUMBER
            .. ' %d %d %d %d %d %s %d %d %d %d %d %s\n', e.row, e.layer, e.L, e.a, e.b, e.cells, r[1], r[2], r[3], r[4],
            e.sheet, e.sheet_width, e.sheet_height, e.sheet_format, e.sheet_mips, q, table.concat(bins, ' '))
    end
    return lines
end

-- One entry's text and binary blocks, appended to parts.
local function encode_entry(parts, key, analysis)
    local luts = {}
    for name, lut in pairs(analysis.luts) do luts[#luts + 1] = {name, lut} end
    table.sort(luts, function(x, y) return x[1] < y[1] end)
    local kit = analysis.kit
    local patterns = analysis.patterns or {}
    local changed, deps = changed_rows(analysis), analysis.patch_deps or {}
    local tints, zones = tint_lines(analysis.tint_of), zone_lines(analysis.zones)
    local emblems = emblem_lines(analysis.emblems)
    parts[#parts + 1] = string.format('K %s %08x %s %s %d %d %d %d %d %d %d %d %d %d %d %d\n', key, kit.id,
        kit.kit_type, kit.archive, analysis.body, #analysis.rows, #analysis.pieces, #luts, #patterns,
        analysis.geometry_patched and 1 or 0, #changed, #deps, #tints, #zones, analysis.emblem_layers or 0, #emblems)
    encode_rows(parts, analysis.rows, changed)
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
    for _, d in ipairs(deps) do
        parts[#parts + 1] = string.format('D %s %s %s %s\n', d.archive, d.name, d.kind, d.hash)
    end
    for _, line in ipairs(tints) do parts[#parts + 1] = line end
    for _, line in ipairs(zones) do parts[#parts + 1] = line end
    for _, line in ipairs(emblems) do parts[#parts + 1] = line end
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
        if r[1] ~= 'R' or #r ~= 17 then error('cache: bad row', 0) end
        analysis.rows[i] = {key = r[2], lut = r[3], row = number(r[4]), area = number(r[5]), under = number(r[6]),
                            L = number(r[7]), a = number(r[8]), b = number(r[9]), metal = r[10] == '1',
                            camo = r[11] == '1', mode = number(r[12]), full = r[13] == '1', ar = number(r[14]),
                            ag = number(r[15]), ab = number(r[16]), emissive = number(r[17])}
    end
    return at
end

-- `count` V lines from `at` onto analysis.rows (by key); the position after them.
local function decode_changes(text, at, count, analysis)
    local by_key = {}
    for _, r in ipairs(analysis.rows) do by_key[r.key] = r end
    for _ = 1, count do
        local v
        v, at = line_at(text, at)
        local row = v[1] == 'V' and #v == 10 and by_key[v[2]]
        if not row then error('cache: bad changed row', 0) end
        row.finish_changed = v[3] == '1'
        if v[4] == '1' then
            row.vanilla = {L = number(v[5]), a = number(v[6]), b = number(v[7]), ar = number(v[8]), ag = number(v[9]),
                           ab = number(v[10])}
        end
    end
    return at
end

-- `count` D lines from `at` into analysis.patch_deps; the position after them.
local function decode_deps(text, at, count, analysis)
    if count == 0 then return at end
    analysis.patch_deps = {}
    for i = 1, count do
        local d
        d, at = line_at(text, at)
        if d[1] ~= 'D' or #d ~= 5 then error('cache: bad patched resource', 0) end
        analysis.patch_deps[i] = {archive = d[2], name = d[3], kind = d[4], hash = d[5]}
    end
    return at
end

-- `count` C lines from `at` into analysis.tint_of (the cape LUT among its LUTs); the position after them.
local function decode_tints(text, at, count, analysis)
    if count == 0 then return at end
    analysis.tint_of = {}
    for _ = 1, count do
        local c
        c, at = line_at(text, at)
        if c[1] ~= 'C' or #c ~= 3 or not analysis.luts[c[2]] then error('cache: bad tint', 0) end
        analysis.tint_of[c[2]] = c[3]
    end
    return at
end

-- `count` Z lines from `at` into analysis.zones; the position after them.
local function decode_zones(text, at, count, analysis)
    if count == 0 then return at end
    analysis.zones = {}
    for _ = 1, count do
        local z
        z, at = line_at(text, at)
        if z[1] ~= 'Z' or #z < 4 then error('cache: bad zone', 0) end
        local by_row = analysis.zones[number(z[2])] or {}
        analysis.zones[number(z[2])] = by_row
        local counts = {}
        for k = 4, #z do counts[k - 4] = number(z[k]) end
        by_row[number(z[3])] = counts
    end
    return at
end

-- `count` E lines from `at` into analysis.emblems; the position after them.
local function decode_emblems(text, at, count, analysis)
    analysis.emblems = {}
    for i = 1, count do
        local e
        e, at = line_at(text, at)
        if e[1] ~= 'E' or #e < 18 then error('cache: bad emblem', 0) end
        local counts = {}
        for k = 18, #e do counts[k - 18] = number(e[k]) end
        local rect = number(e[8]) >= 0 and {number(e[8]), number(e[9]), number(e[10]), number(e[11])} or nil
        analysis.emblems[i] = {row = number(e[2]), layer = number(e[3]), L = number(e[4]), a = number(e[5]),
                               b = number(e[6]), cells = number(e[7]), rect = rect, sheet = e[12],
                               sheet_width = number(e[13]), sheet_height = number(e[14]),
                               sheet_format = number(e[15]), sheet_mips = number(e[16]),
                               around = {[number(e[17])] = counts}}
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
    if f[1] ~= 'K' or #f ~= 17 then error('cache: bad entry', 0) end
    local analysis = {kit = {id = tonumber(f[3], 16), kit_type = f[4], archive = f[5]}, body = number(f[6]),
                      rows = {}, pieces = {}, luts = {}, patterns = {}, cached = true, geometry_patched = f[11] == '1',
                      emblem_layers = number(f[16])}
    at = decode_rows(text, at, number(f[7]), analysis)
    at = decode_changes(text, at, number(f[12]), analysis)
    at = decode_pieces(text, at, number(f[8]), analysis)
    at = decode_patterns(text, at, number(f[10]), analysis)
    at = decode_luts(text, at, number(f[9]), analysis, bytes)
    at = decode_deps(text, at, number(f[13]), analysis)
    at = decode_tints(text, at, number(f[14]), analysis)
    at = decode_zones(text, at, number(f[15]), analysis)
    at = decode_emblems(text, at, number(f[17]), analysis)
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

-- The file is read and written in pieces of CHUNK bytes with yield() between them (a full file is about 1.4 MB:
-- up to about 5 ms in one piece in real play v1.2).
Cache.CHUNK = 131072

-- The file's text, or nil. yield (optional): called after each piece.
function Cache.read(path, yield)
    local file = path and io.open(path, 'rb')
    if not file then return nil end
    local pieces = {}
    while true do
        local piece = file:read(Cache.CHUNK)
        if not piece then break end
        pieces[#pieces + 1] = piece
        if yield then yield() end
    end
    file:close()
    return table.concat(pieces)
end

-- Writes text through <path>.tmp and a rename; true, or false and why (the previous file stays). yield (optional):
-- called after each piece and before the rename.
function Cache.write(path, text, yield)
    local temp = path .. '.tmp'
    local file, reason = io.open(temp, 'wb')
    if not file then return false, reason end
    local written, write_error = true, nil
    for at = 1, #text, Cache.CHUNK do
        written, write_error = file:write(text:sub(at, at + Cache.CHUNK - 1))
        if not written then break end
        if yield then yield() end
    end
    local closed, close_error = file:close()
    if not (written and closed) then
        os.remove(temp)
        return false, write_error or close_error
    end
    if yield then yield() end
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
    for _, fn in ipairs({Cache.pieces_sum, Cache.key, Cache.header, number, encode_rows, changed_rows, tint_lines,
                         zone_lines, emblem_lines, decode_emblems,
                         encode_entry, decode_zones,
                         encode_samples, Cache.encode,
                         line_at, decode_rows, decode_changes, decode_deps, decode_tints, decode_pieces, decode_patterns,
                         decode_luts,
                         decode_samples,
                         decode_entry, Cache.decode,
                         Cache.path, Cache.read, Cache.write}) do
        jit.off(fn, true)
    end
end

return Cache
