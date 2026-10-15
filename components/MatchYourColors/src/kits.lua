-- Match Your Colors: a kit's color rows, built from the game's own files at runtime (no data shipped with the
-- mod, so new helmets and armors work as they are released).
--
-- A kit lists pieces {unit path, slot, type, body, material LUT override, tone variations}. Each piece's unit
-- names its materials; each material names its default LUT and ID mask. The kit's own archive holds them,
-- except the shared cape mounts, which are in the shared customization archive (also holding the detail and
-- camo tilers). A piece whose unit is in neither is left out, as is a material whose LUT is in neither; a
-- missing ID mask gives uniform rows. This is the data scope of research/eval_scope.py: matcher v10 on it
-- equals the proven quality on all 42,660 pairs.
--
-- Row area = piece weight x ID-mask coverage / materials of the piece. A piece with skin tones (tone variations)
-- counts like any other: its LUT materials are clothing (the PH-9 Predator's camo shirt, the IE-57 Hell-Bent's vest,
-- the O-2 Heavy Operator's sleeves) and its skin shows no material LUT row in the appearance study's row maps; until
-- 2026-10-09 such pieces added no rows and were never recolored (user ticket: those shirts kept their own yellow and
-- green). Patterns (v11.4, research/patterns.py): a piece's pattern texture (the kit's, else the material's default)
-- is drawn where the material's pattern mask is set; pattern area = piece weight x mask coverage (mip
-- PATTERN_MIP of its layer) / materials of the piece, per pattern texture. Nothing here runs per frame:
-- Kits.analyse runs inside a recolor job and calls yield() between steps.
local ffi = require('ffi')

local Kits = {}

Kits.TYPE_UNIT, Kits.TYPE_MATERIAL, Kits.TYPE_TEXTURE = 'e0a48d0be9a7453f', 'eac0b497876adedf', 'cd4238c6a0c69e32'
Kits.SLOT_LUT, Kits.SLOT_MASK = 0x7e662968, 0xb281e5f2
Kits.SLOT_PATTERN, Kits.SLOT_PATTERN_MASK = 0x81d4c49d, 0x05a27dd5
Kits.PATTERN_MIP = 2
Kits.DETAIL_TILER, Kits.CAMO_TILER = '5015467d918378bf', 'f8b2508e99fb9f28'
-- Archives searched for the shared resources, in order (the first holding the detail tiler is used).
Kits.SHARED_ARCHIVES = {'18235e0c9ec0e636', 'ee6b1ba7e22d71ed'}
Kits.NO_LUT = '0000000000000000'

Kits.HELMET, Kits.ARMOR = 'Helmet', 'Armor'
Kits.SLOTS = {[0] = 'helmet', 'cape', 'torso', 'hips', 'left_leg', 'right_leg', 'left_arm', 'right_arm',
              'left_shoulder', 'right_shoulder'}
Kits.UNDERGARMENT = 1
Kits.BODY_ANY = 3
-- Piece weights of matcher v10: helmet kits by (slot, type), armor kits by slot x type. The cape slot weighs
-- nothing (v11.5): every armor carries one of two generic cape pieces, whose colors are not its design (their yellow
-- rows made the CM-09 Bonesnapper's accent yellow).
local HELMET_WEIGHT = {['0:0'] = 1.0, ['0:2'] = 0.3}
local ARMOR_SLOT_WEIGHT = {[0] = 0.0, 0.0, 0.30, 0.12, 0.10, 0.10, 0.06, 0.06, 0.05, 0.05}
local ARMOR_TYPE_WEIGHT = {[0] = 1.0, 0.5, 0.4}

local HIGH = 4294967296
local u32 = function(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
local function hex64(p, o) return string.format('%08x%08x', u32(p, o + 4), u32(p, o)) end

-- The weight of a piece in the color model; 0 leaves it out. body: the avatar's body type (0 stocky, 1 slim).
function Kits.weight(kit_type, piece, body)
    if kit_type == Kits.HELMET then return HELMET_WEIGHT[piece.slot .. ':' .. piece.type] or 0.0 end
    if piece.body ~= body and piece.body ~= Kits.BODY_ANY then return 0.0 end
    return (ARMOR_SLOT_WEIGHT[piece.slot] or 0.0) * (ARMOR_TYPE_WEIGHT[piece.type] or 0.0)
end

-- The material slots of a unit's main part in file order: {material hash, ...} (a repeated slot key keeps its
-- first position and its last value, as a Python dict does).
local function unit_materials(slim, archive, record, scratch)
    local head = scratch(116)
    slim.part(archive, record, 'main', 0, 116, head, 0)
    local at = u32(head, 112)
    if at == 0 then return {} end
    local count_bytes = scratch(4)
    slim.part(archive, record, 'main', at, 4, count_bytes, 0)
    local n = u32(count_bytes, 0)
    local map = scratch(4 + 12 * n)
    slim.part(archive, record, 'main', at, 4 + 12 * n, map, 0)
    local order, by_key = {}, {}
    for i = 0, n - 1 do
        local key = u32(map, 4 + 4 * i)
        local value = hex64(map, 4 + 4 * n + 8 * i)
        if not by_key[key] then order[#order + 1] = key end
        by_key[key] = value
    end
    local out = {}
    for i, key in ipairs(order) do out[i] = by_key[key] end
    return out
end

-- A material's texture slots: {slot number -> texture hash}, and its parent (its shader template's hash, +24).
local function material_textures(slim, archive, record, scratch)
    local head = scratch(136)
    slim.part(archive, record, 'main', 0, 136, head, 0)
    local n = u32(head, 64)
    local data = scratch(136 + 12 * n)
    slim.part(archive, record, 'main', 0, 136 + 12 * n, data, 0)
    local out = {}
    for i = 0, n - 1 do out[u32(data, 136 + 4 * i)] = hex64(data, 136 + 4 * n + 8 * i) end
    return out, hex64(head, 24)
end

-- Texture loaders with per-session caches: lut(hash) -> {values, width, height} or nil, coverage(hash) ->
-- array or nil, pattern(hash) -> {values, width, height} of a 3 x 1 R16G16B16A16_FLOAT pattern texture or nil,
-- pattern_coverage(hash, layer) -> number or nil. deps: {slim, texture (src/texture.lua), find, scratch,
-- big_scratch (ID-mask row blocks, up to Texture.COVERAGE_BLOCK bytes), yield}, read at each call (the reader and
-- its buffers exist only while a job runs).
-- A texture's error with its name and, when a mod's patch served it, the patch file (v1.3 logged only "unsupported
-- texture format 2", user report 2026-10-08).
local function texture_error(name, record, why)
    return string.format('texture %s%s: %s', name, record and record.file and (' (from ' .. record.file .. ')') or '',
                         tostring(why))
end

function Kits.textures(deps)
    local Texture = deps.texture
    local luts, coverages = {}, {}
    local self = {luts = luts}

    local function describe(name)
        local slim = deps.slim
        local archive, record = deps.find(name, Kits.TYPE_TEXTURE)
        if not archive then return nil end
        local size = slim.part_size(record, 'main')
        local main = deps.scratch(size)
        slim.part(archive, record, 'main', 0, size, main, 0)
        local ok, info = pcall(Texture.describe, main, size)
        if not ok then error(texture_error(name, record, info), 0) end
        return info, Texture.pixels(slim, archive, record, info), record
    end

    -- A texture's description and pixel reader (Texture.describe, Texture.pixels) and record, or nil (src/albedo.lua).
    self.describe = describe

    function self.lut(name)
        local found = luts[name]
        if found ~= nil then return found or nil end
        local info, pixels, record = describe(name)
        if not info then luts[name] = false return nil end
        local ok, values, width, height = pcall(Texture.lut, pixels, info, deps.scratch)
        if not ok then error(texture_error(name, record, values), 0) end
        found = {values = values, width = width, height = height}
        luts[name] = found
        return found
    end

    function self.coverage(name)
        local found = coverages[name]
        if found ~= nil then return found or nil end
        local info, pixels = describe(name)
        found = info and Texture.coverage(pixels, info, deps.big_scratch, deps.yield) or false
        coverages[name] = found
        return found or nil
    end

    -- A pattern texture or mask this file cannot decode (another format) counts as none: the pattern is left out.
    local function describe_any(name)
        local ok, info, pixels = pcall(describe, name)
        if ok then return info, pixels end
        return nil
    end

    local patterns, pattern_coverages = {}, {}
    function self.pattern(name)
        local found = patterns[name]
        if found ~= nil then return found or nil end
        local info, pixels = describe_any(name)
        found = false
        if info and (info.format == Texture.FORMAT_RGBA16F or info.format == Texture.FORMAT_RGBA32F) and info.width == 3
            and info.height == 1 then
            local values, width, height = Texture.lut(pixels, info, deps.scratch)
            found = {values = values, width = width, height = height}
        end
        patterns[name] = found
        return found or nil
    end

    function self.pattern_coverage(name, layer)
        local key = name .. ':' .. layer
        local found = pattern_coverages[key]
        if found ~= nil then return found or nil end
        local info, pixels = describe_any(name)
        found = info and Texture.mask_coverage(pixels, info, layer, Kits.PATTERN_MIP, deps.scratch, deps.yield) or false
        pattern_coverages[key] = found
        return found or nil
    end
    return self
end

-- The detail and camo samples (research/effective.py: the first 512 texels of the detail tiler's mip 4 and of
-- the camo tiler's mip 2, every layer) and the shared archive they came from; nil when no shared archive holds
-- the detail tiler.
function Kits.shared_samples(slim, Texture, scratch, yield)
    for _, archive in ipairs(Kits.SHARED_ARCHIVES) do
        local detail = slim.locate(archive, Kits.DETAIL_TILER, Kits.TYPE_TEXTURE)
        local camo = slim.locate(archive, Kits.CAMO_TILER, Kits.TYPE_TEXTURE)
        if detail and camo then
            local out = {archive = archive}
            for name, spec in pairs({detail = {detail, 4}, camo = {camo, 2}}) do
                local size = slim.part_size(spec[1], 'main')
                local main = scratch(size)
                slim.part(archive, spec[1], 'main', 0, size, main, 0)
                local info = Texture.describe(main, size)
                out[name] = Texture.samples(Texture.pixels(slim, archive, spec[1], info), info, spec[2], 512, scratch,
                                            yield)
                out[name .. '_layers'] = info.layers
            end
            return out
        end
    end
    return nil
end

-- entry.pattern: the kit piece's pattern texture, else the material's default (slot SLOT_PATTERN), when found;
-- entry.pattern_mask: the material's pattern mask (slot SLOT_PATTERN_MASK), when found too.
local function add_pattern_textures(entry, deps, piece, textures)
    local pattern = piece.pattern and piece.pattern ~= Kits.NO_LUT and piece.pattern or textures[Kits.SLOT_PATTERN]
    if not pattern or pattern == Kits.NO_LUT or not deps.find(pattern, Kits.TYPE_TEXTURE) then return end
    entry.pattern = pattern
    local mask = textures[Kits.SLOT_PATTERN_MASK]
    if mask and mask ~= Kits.NO_LUT and deps.find(mask, Kits.TYPE_TEXTURE) then entry.pattern_mask = mask end
end

-- A material's entry: with a material LUT, {material, lut, mask, pattern, pattern_mask}; without one, a mod's material
-- of gear whose albedo holds its colors (src/albedo.lua, v1.5: the Cowboy Hat), {material, albedo, mra}; else nil,
-- and why when it is a mod's material src/albedo.lua cannot read.
local function material_entry(deps, piece, material, record, textures, parent)
    local default = textures[Kits.SLOT_LUT]
    if not default then
        if not deps.Albedo then return nil end
        local entry, why = deps.Albedo.eligible(record, parent, textures, deps.textures.describe)
        if entry then entry.material = material end
        return entry, record.file and why or nil
    end
    local lut = piece.lut ~= Kits.NO_LUT and piece.lut or default
    if not deps.find(lut, Kits.TYPE_TEXTURE) then return nil end
    local entry = {material = material, lut = lut, mask = textures[Kits.SLOT_MASK]}
    add_pattern_textures(entry, deps, piece, textures)
    return entry
end

-- The materials of one piece that carry a material LUT (or an albedo with the colors, above), in the unit's order, or
-- nil when the piece's unit is not in the searched archives. pattern: the kit's pattern texture, else the material's
-- default, when found; pattern_mask: the material's pattern mask, when found too. Also the mods' materials without a
-- color table left unread: {{material, file, why}, ...} or nil.
local function piece_materials(deps, piece)
    local archive, record = deps.find(piece.path, Kits.TYPE_UNIT)
    if not archive then return nil end
    local out, unread = {}, nil
    for _, material in ipairs(unit_materials(deps.slim, archive, record, deps.scratch)) do
        local m_archive, m_record = deps.find(material, Kits.TYPE_MATERIAL)
        if m_archive then
            local textures, parent = material_textures(deps.slim, m_archive, m_record, deps.scratch)
            local entry, why = material_entry(deps, piece, material, m_record, textures, parent)
            out[#out + 1] = entry
            if why then
                unread = unread or {}
                unread[#unread + 1] = {material = material, file = m_record.file, why = why}
            end
        end
        deps.yield()
    end
    return out, unread
end

-- Adds one material's pattern area to the accumulators (weight x mask coverage / materials) when its pattern is
-- drawn (texel 0 w is a mask layer, not -1); the pattern texture joins out.luts.
local function add_pattern(acc, out, deps, weight, count, material)
    if not material.pattern or not material.pattern_mask then return end
    local pattern = deps.textures.pattern(material.pattern)
    if not pattern or pattern.values[3] == -1 then return end
    local w = pattern.values[3]
    local coverage = deps.textures.pattern_coverage(material.pattern_mask, w >= 0 and math.floor(w) or math.ceil(w))
    if not coverage then return end
    local name = material.pattern
    if acc.pattern_area[name] == nil then
        acc.pattern_order[#acc.pattern_order + 1] = name
        acc.pattern_area[name] = 0.0
        out.luts[name] = pattern
    end
    acc.pattern_area[name] = acc.pattern_area[name] + weight * coverage / count
end

-- Adds one material's rows to the accumulators: area = weight x coverage / materials. Row 0 is always added (area 0
-- where coverage is 0): the shader draws a texel whose slot weights are (near) blank with row 0, and coverage leaves
-- those texels out; the PH-56 Jaguar's shin wraps (their mask 71% blank, 8% of its measured view) kept their color
-- (image review 2026-10-09). Such a row takes its group's color and weighs nothing (src/matcher.lua measure_rows).
local function add_rows(acc, piece, weight, count, material, lut, coverage)
    local n = lut.height
    local cov = coverage
    if not cov then
        cov = {}
        for r = 1, n do cov[r] = 1.0 / n end
    end
    for r = 0, math.min(n, #cov) - 1 do
        local area = weight * cov[r + 1] / count
        if area > 1e-6 or r == 0 then
            local key = material.lut .. ':' .. r
            if acc.area[key] == nil then
                acc.order[#acc.order + 1] = key
                acc.area[key], acc.under[key], acc.row_of[key] = 0.0, 0.0, {material.lut, r}
            end
            acc.area[key] = acc.area[key] + area
            if piece.type == Kits.UNDERGARMENT then acc.under[key] = acc.under[key] + area end
        end
    end
end

-- A material whose albedo holds its colors (src/albedo.lua): its clusters read once per analysis (out.albedos), each
-- a row of area weight x its share / materials (key '<albedo>:<cluster - 1>'; undergarment pieces' as under).
local function add_albedo(acc, out, deps, piece, weight, count, material)
    out.albedos = out.albedos or {}
    local albedo = out.albedos[material.albedo]
    if albedo == nil then
        albedo = deps.Albedo.read(material, deps.textures.describe, deps.Colour, deps.yield) or false
        out.albedos[material.albedo] = albedo
    end
    for k, c in ipairs(albedo and albedo.clusters or {}) do
        local key, area = material.albedo .. ':' .. (k - 1), weight * c.share / count
        if acc.area[key] == nil then
            acc.order[#acc.order + 1] = key
            acc.area[key], acc.under[key], acc.row_of[key] = 0.0, 0.0, {material.albedo, k - 1}
        end
        acc.area[key] = acc.area[key] + area
        if piece.type == Kits.UNDERGARMENT then acc.under[key] = acc.under[key] + area end
    end
end

-- A mod's materials without a color table left unread (piece_materials), once per analysis (out.unread: {[material]
-- = {material, file, why}}, for the job's log).
local function note_unread(out, unread)
    for _, u in ipairs(unread or {}) do
        out.unread = out.unread or {}
        out.unread[u.material] = u
    end
end

-- One piece: its materials (when spawned for this body) and, for a weighted piece, its rows. skin: the piece has
-- skin tones (kept for the cache and logs; it no longer leaves the piece out).
local function add_piece(acc, out, kit, piece, body, deps)
    local weight = Kits.weight(kit.kit_type, piece, body)
    -- Pieces of the other body type are never spawned for this avatar: not read at all.
    local spawned = piece.body == body or piece.body == Kits.BODY_ANY or kit.kit_type == Kits.HELMET
    local materials, unread
    if spawned then materials, unread = piece_materials(deps, piece) end
    note_unread(out, unread)
    if spawned and not materials then out.dropped = out.dropped + 1 end
    local entry = {piece = piece, weight = weight, materials = materials or {}, skin = piece.tone > 0}
    out.pieces[#out.pieces + 1] = entry
    if weight <= 0 or not materials then return end
    for _, material in ipairs(materials) do
        if material.albedo then
            add_albedo(acc, out, deps, piece, weight, #materials, material)
        else
            local lut = deps.textures.lut(material.lut)
            out.luts[material.lut] = lut
            local coverage = material.mask and deps.find(material.mask, Kits.TYPE_TEXTURE)
                and deps.textures.coverage(material.mask) or nil
            add_rows(acc, piece, weight, #materials, material, lut, coverage)
            add_pattern(acc, out, deps, weight, #materials, material)
        end
        deps.yield()
    end
end

-- A row's emissive intensity (column 13 x): above 0 a paint row glows (the game's light strips; glowing visors of
-- LUT mods). lut: {values, width, height}.
function Kits.emissive(lut, r)
    if lut.width <= 13 then return 0 end
    return lut.values[(r * lut.width + 13) * 4]
end

-- A LUT row's colors and flags (the color model's row_info), and an albedo cluster's (src/albedo.lua: its look, its
-- mean albedo, metal over half its texels; paint, mode 0, no camo).
local function lut_row(lut, r, deps)
    local L, a, b, metal, camo, mode, full, ar, ag, ab = deps.colour.row_info(lut.values, lut.width, r)
    return {L = L, a = a, b = b, metal = metal, camo = camo, mode = mode, full = full, ar = ar, ag = ag, ab = ab,
            emissive = Kits.emissive(lut, r)}
end
local function albedo_row(albedo, r)
    local c = albedo.clusters[r + 1]
    return {L = c.seen[1], a = c.seen[2], b = c.seen[3], metal = c.metal > 0.5, camo = false, mode = 0,
            full = c.metal >= 0.9, ar = c.lin[1], ag = c.lin[2], ab = c.lin[3], emissive = 0, albedo = true}
end

-- A kit's analysis for one body type: {kit, rows = {{key, area, under, L, a, b, metal, camo, mode, full, ar, ag,
-- ab (mean linear albedo), emissive}, ...},
-- pieces = {{piece, weight, materials, skin}}, luts = {hash -> {values, width, height}} (pattern textures too),
-- patterns = {{pattern, area}, ...} in first-seen order}. deps: {slim,
-- find (the kit's archive, then the shared one), scratch, yield, textures (Kits.textures), colour
-- (Colour.new model)}.
function Kits.analyse(kit, body, deps)
    local acc = {order = {}, area = {}, under = {}, row_of = {}, pattern_order = {}, pattern_area = {}}
    local out = {kit = kit, body = body, pieces = {}, luts = {}, dropped = 0}
    for _, piece in ipairs(kit.pieces) do add_piece(acc, out, kit, piece, body, deps) end
    out.rows = {}
    for _, key in ipairs(acc.order) do
        local lut_name, r = acc.row_of[key][1], acc.row_of[key][2]
        local row = out.luts[lut_name] and lut_row(out.luts[lut_name], r, deps) or albedo_row(out.albedos[lut_name], r)
        row.key, row.lut, row.row, row.area, row.under = key, lut_name, r, acc.area[key], acc.under[key]
        out.rows[#out.rows + 1] = row
        deps.yield()
    end
    out.patterns = {}
    for _, name in ipairs(acc.pattern_order) do
        out.patterns[#out.patterns + 1] = {pattern = name, area = acc.pattern_area[name]}
    end
    return out
end

-- The color columns of a LUT row (their RGB; src/transfer.lua's): every other value is the row's finish.
local COLOR_COLUMNS = {[0] = true, [2] = true, [5] = true, [6] = true, [16] = true, [17] = true, [18] = true,
                       [19] = true}

-- How row r of lut differs from the archived original (both {values, width, height}): 'finish' when a value outside
-- the color columns' RGB differs (or the row is new), 'color' when only those differ, nil when it is the same.
local function row_change(lut, original, r)
    if original.width ~= lut.width or r >= original.height then return 'finish' end
    local color = false
    for c = 0, lut.width - 1 do
        for ch = 0, 3 do
            local i = (r * lut.width + c) * 4 + ch
            local x, y = lut.values[i], original.values[i]
            if math.abs(x - y) > 1e-3 * math.max(1, math.abs(y)) then
                if not (COLOR_COLUMNS[c] and ch < 3) then return 'finish' end
                color = true
            end
        end
    end
    return color and 'color' or nil
end

-- Whether a weighted piece's geometry came from a patch: its unit, a material, an ID mask or a pattern mask.
local function piece_patched(entry, patched)
    if patched[entry.piece.path .. ' ' .. Kits.TYPE_UNIT] then return true end
    for _, m in ipairs(entry.materials) do
        if patched[m.material .. ' ' .. Kits.TYPE_MATERIAL] or (m.mask and patched[m.mask .. ' ' .. Kits.TYPE_TEXTURE])
            or (m.pattern_mask and patched[m.pattern_mask .. ' ' .. Kits.TYPE_TEXTURE]) then
            return true
        end
    end
    return false
end

-- One row of a patched LUT against the archived one (original(name) -> LUT or nil): finish_changed and vanilla.
local function mark_row(row, lut, original, colour)
    local base = original(row.lut)
    local change = not base and 'finish' or row_change(lut, base, row.row)
    if not change then return end
    row.finish_changed = change == 'finish'
    if base and row.row < base.height then
        local L, a, b, _, _, _, _, ar, ag, ab = colour.row_info(base.values, base.width, row.row)
        row.vanilla = {L = L, a = a, b = b, ar = ar, ag = ag, ab = ab}
    end
end

-- What an analysis read from mods' patches (touched: {['<archive> <name> <type>'] = record} of the patched
-- resources the job's reader served; KB match-your-colors-review-transmog-v13). geometry_patched: a weighted piece's
-- unit, material, ID mask or pattern mask came from a patch (its measured screen pixels no longer hold). On each row
-- of a patched LUT that differs from the archived one (original(name) -> {values, width, height} or nil):
-- finish_changed (a value outside the color columns' RGB differs: its measured response no longer holds) and
-- vanilla = {L, a, b, ar, ag, ab}, the archived row's model color and albedo (the measured light is rescaled from
-- them, src/matcher.lua). colour: the color model (row_info).
function Kits.mark_patched(analysis, touched, original, colour)
    local patched = {}
    for key in pairs(touched) do patched[key:match('^%S+ (%S+ %S+)$')] = true end
    for _, entry in ipairs(analysis.pieces) do
        if entry.weight > 0 and piece_patched(entry, patched) then analysis.geometry_patched = true end
    end
    for _, row in ipairs(analysis.rows) do -- an albedo's clusters are no LUT rows (src/albedo.lua)
        if patched[row.lut .. ' ' .. Kits.TYPE_TEXTURE] and not row.albedo then
            mark_row(row, analysis.luts[row.lut], original, colour)
        end
    end
    return analysis
end

-- A kit record's content as one string (its fields and every piece): an analysis is made of what a record lists, and
-- a record another mod recomposes at runtime (a transmog's carrier) lists other pieces under the same id. Made once
-- per kit (weak keys): a kit is not changed once read (kit_of), and the catalogue gives the kit it kept while
-- its record reads the same; in game a plan kept from before spent most of its job on the keys made from it
-- (harness profile 2026-10-11, KB match-your-colors-stress-test).
local signatures = setmetatable({}, {__mode = 'k'})
function Kits.signature(kit)
    local made = signatures[kit]
    if made then return made end
    local parts = {string.format('%08x', kit.id), tostring(kit.name_upper), tostring(kit.archive), tostring(kit.kit_type)}
    for _, p in ipairs(kit.pieces) do
        parts[#parts + 1] = table.concat({p.path, p.slot, p.type, p.body, p.lut, p.pattern or '', p.tone, p.fields or ''},
                                         ',') .. (p.cape_lut and (',' .. p.cape_lut .. ',' .. (p.gradient or '') .. ','
                                                    .. (p.decal or '')) or '')
    end
    made = table.concat(parts, ';')
    signatures[kit] = made
    return made
end

-- The kit catalogue in game memory (customization manager [game + 0x33264F8]: kit pointers at +0, count
-- at +8). read(address, size, buffer) -> true. Kits are read on demand; src/recolor.lua reads a record again on
-- every job.
Kits.KIT_ID, Kits.KIT_NAME_UPPER, Kits.KIT_ARCHIVE, Kits.KIT_TYPE = 0, 12, 32, 40
Kits.KIT_BODIES, Kits.KIT_BODY_COUNT = 48, 56
Kits.BODY_RECORD, Kits.PIECE_RECORD = 24, 96
local KIT_TYPES = {[0] = Kits.ARMOR, Kits.HELMET, 'Cape'}

-- One piece record (at buffer[o]) of a body: {path, slot, type, body, lut, pattern, tone} and, for a cape, its cape
-- LUT (+40: the tint and emblem-layer parameters per row), gradient (+48: where the tint shows), decal scalar fields
-- (+64: which LUT row shows where) and decal sheet (+80: the emblems' own colors; src/capes.lua).
local function piece_of(buffer, o, body, cape)
    local piece = {path = hex64(buffer, o), slot = u32(buffer, o + 8), type = u32(buffer, o + 12), body = body,
                   lut = hex64(buffer, o + 24), pattern = hex64(buffer, o + 32), tone = buffer[o + 88]}
    if cape then
        piece.cape_lut, piece.gradient = hex64(buffer, o + 40), hex64(buffer, o + 48)
        piece.fields, piece.decal = hex64(buffer, o + 64), hex64(buffer, o + 80)
    end
    return piece
end

-- A kit record's bytes, read into `record` (Kits.record(): at least RECORD_BYTES): its 64 bytes, then its bodies (24
-- each, one read), then each body's pieces (96 each, one read a body: v1.3 read every body and piece apart). Returns
-- how many bytes it holds, or nil and why.
local MAX_BODIES, MAX_PIECES = 8, 32
Kits.RECORD_BYTES = 64 + MAX_BODIES * Kits.BODY_RECORD + MAX_BODIES * MAX_PIECES * Kits.PIECE_RECORD
local function read_record(read, address, record)
    if not read(address, 64, record) then return nil, 'kit unreadable' end
    local body_count = u32(record, 56)
    if not KIT_TYPES[u32(record, 40)] or body_count > MAX_BODIES then return nil, 'unexpected kit record' end
    local at = 64 + body_count * Kits.BODY_RECORD
    if body_count > 0 and not read(u32(record, 48) + u32(record, 52) * HIGH, at - 64, record + 64) then
        return nil, 'kit body unreadable'
    end
    for b = 0, body_count - 1 do
        local o = 64 + Kits.BODY_RECORD * b
        local count = u32(record, o + 16)
        if count > MAX_PIECES then return nil, 'unexpected kit body' end
        if count > 0 and not read(u32(record, o + 8) + u32(record, o + 12) * HIGH, count * Kits.PIECE_RECORD,
                                  record + at) then
            return nil, 'kit piece unreadable'
        end
        at = at + count * Kits.PIECE_RECORD
    end
    return at
end

-- The kit of a record read_record read (size: its bytes): {id, name_upper, archive, kit_type, pieces (piece_of's)}.
local function kit_of(record)
    local kit = {id = u32(record, 0), name_upper = u32(record, 12), archive = hex64(record, 32),
                 kit_type = KIT_TYPES[u32(record, 40)], pieces = {}}
    local body_count = u32(record, 56)
    local at = 64 + body_count * Kits.BODY_RECORD
    for b = 0, body_count - 1 do
        local o = 64 + Kits.BODY_RECORD * b
        local body, count = u32(record, o), u32(record, o + 16)
        for p = 0, count - 1 do
            kit.pieces[#kit.pieces + 1] = piece_of(record, at + p * Kits.PIECE_RECORD, body, kit.kit_type == 'Cape')
        end
        at = at + count * Kits.PIECE_RECORD
    end
    return kit
end

Kits.record = function() return ffi.new('uint8_t[?]', Kits.RECORD_BYTES) end

-- The game's kit catalogue (customization manager [game + 0x33264F8]: kit pointers at +0, count at +8):
-- find(id) -> kit (kit_of), its record read again on every call (a job's three): a transmog mod
-- recomposes a record at runtime under the same id (its carrier, KB match-your-colors-review-transmog-v13), and the
-- kit kept is replaced when the record lists anything else. A record whose bytes read as they did gives the kit kept
-- without decoding it (v1.3 decoded every read and compared their signatures). signature(id): the record's content
-- now (no catalogue scan, no pause; nil before the first lookup). The first lookup reads every kit's id (one read
-- each); a miss reads them again once (kits loaded later).
function Kits.catalogue(memory, game, yield)
    local u8p = 'const uint8_t *'
    local function read(address, size, out) return memory.read_into(ffi.cast(u8p, address), size, out) end
    local function u64(b, o)
        return (b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216) + (b[o + 4] + b[o + 5] * 256) * HIGH
    end
    local addresses, kits, bytes = nil, {}, {} -- bytes[id]: the record bytes kits[id] was read from
    local buffer, record = ffi.new('uint8_t[16]'), Kits.record()

    local function scan()
        addresses = {}
        if not read(game + 0x33264F8, 8, buffer) then error('kit catalogue unreadable', 0) end
        local manager = u64(buffer, 0)
        if not read(manager, 16, buffer) then error('kit catalogue unreadable', 0) end
        local pointers = u64(buffer, 0)
        local count = buffer[8] + buffer[9] * 256 + buffer[10] * 65536 + buffer[11] * 16777216
        if count == 0 or count > 4096 then error('unexpected kit catalogue', 0) end
        local list = ffi.new('uint8_t[?]', count * 8)
        if not read(pointers, count * 8, list) then error('kit catalogue unreadable', 0) end
        for i = 0, count - 1 do
            if i % 64 == 63 then yield() end
            local address = u64(list, i * 8)
            if read(address, 4, buffer) then
                addresses[buffer[0] + buffer[1] * 256 + buffer[2] * 65536 + buffer[3] * 16777216] = address
            end
        end
    end

    -- The kit at `address` as its record reads now: the kit kept for id while its bytes are the same, or one with the
    -- same signature (the record moved), else the new one, kept. nil and why when unreadable.
    local function current(id, address)
        local size, why = read_record(read, address, record)
        if not size then return nil, why end
        local now, known = ffi.string(record, size), kits[id]
        if known and bytes[id] == now then return known end
        local kit = kit_of(record)
        if not (known and Kits.signature(known) == Kits.signature(kit)) then kits[id] = kit end
        bytes[id] = now
        return kits[id]
    end

    local self = {}
    function self.find(id)
        if not addresses or not addresses[id] then scan() end
        local address = addresses[id]
        if not address then error(string.format('kit %08x not in the catalogue', id), 0) end
        local kit, why = current(id, address)
        if not kit then error(why, 0) end
        return kit
    end

    function self.signature(id)
        local address = addresses and addresses[id]
        local kit = address and current(id, address)
        return kit and Kits.signature(kit) or nil
    end
    return self
end
-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({hex64, Kits.weight, unit_materials, material_textures, texture_error, Kits.textures,
        Kits.shared_samples,
        add_pattern_textures, material_entry, piece_materials, add_pattern, add_rows, add_albedo, note_unread,
        add_piece,
        Kits.emissive, lut_row, albedo_row, Kits.analyse,
        row_change, piece_patched, mark_row, Kits.mark_patched, Kits.signature, piece_of, read_record, kit_of,
        Kits.catalogue}) do
        jit.off(fn, true)
    end
end

return Kits
