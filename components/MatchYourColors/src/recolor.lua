-- Match Your Colors: from the local player's kits to recolored materials.
--
-- A job (a coroutine resumed by the frame step with a time budget) reads the two kits from game memory,
-- analyses them from the game's files (src/kits.lua; kept for the session), plans the match
-- (src/matcher.lua) and builds the new LUT data: each planned row keeps its material and takes fitted colors
-- (src/transfer.lua); a planned pattern (v11.4) is a copy of the pattern texture with texel 0's color replaced.
-- The step then applies it in one frame: runtime textures (RenderBufferApi), bound to the target units'
-- materials whose LUT (or pattern) is one the plan changes, meshes committed. Bindings are tracked {unit, mesh,
-- material, slot, vanilla texture object} so they can be put back.
--
-- Texture lifetime: a plan's textures live until the plan changes (another kit, direction or Off) or the
-- addon pauses or stops: then the vanilla textures go back on every live tracked material, and the textures
-- go back to the pool RETIRE_FRAMES frames later (the render thread may still draw a frame that used them). The
-- pool refills a free texture for the next plan instead of making a new one: making a texture waits for the
-- render thread (about one frame, src/engine.lua), refilling one does not.
local ffi = require('ffi')

local Recolor = {}

Recolor.OFF, Recolor.HELMET_FROM_ARMOR, Recolor.ARMOR_FROM_HELMET = 1, 2, 3
Recolor.RETIRE_FRAMES = 4
Recolor.POOL_SPARES = 2 -- free textures made beside one that must be made (that frame waits for the renderer anyway)
Recolor.POOL_MAX_FREE = 32 -- free textures kept per size; one more given back is destroyed
Recolor.POOL_MAX_FREE_SHEETS = 1 -- free decal sheet copies kept (5.6 MB each, and their data)
Recolor.SHEETS_KEPT = 2 -- recolored sheets a session keeps ready (the bound one and the next)
Recolor.SHEET_FORMAT = 77 -- DXGI BC3 (src/texture.lua FORMAT_BC3): the decal sheets recolored
Recolor.SHEET_CHUNK = 262144 -- bytes of a sheet read between two pause points
local SLOTS = {[Recolor.HELMET_FROM_ARMOR] = {0, 0}, [Recolor.ARMOR_FROM_HELMET] = {1, 9}}
local LUT_WIDTH = 23
local HIGH = 4294967296

-- Match Materials: LUT row r of data (width columns) takes the finish of source row `key` ('lut:row' of the source
-- analysis): metallic (column 6 w, clipped to 0-1), no detail metallic controls (column 7: they follow the source's
-- detail and mesh; v1.0's whole-row copies drew chrome specks with them), the source's specular (column 8) and
-- roughness (column 10 x). Mode, detail layer and controls, colors, camo and tiling stay the target's.
function Recolor.apply_finish(data, width, r, source, key)
    local lut, row = key:match('^(%x+):(%d+)$')
    local spec = lut and source.luts[lut]
    if not spec then error('finish source ' .. tostring(key) .. ' not in the source analysis', 0) end
    local v, s = spec.values, tonumber(row) * spec.width * 4
    local t = r * width * 4
    data[t + 27] = math.min(math.max(v[s + 27], 0), 1)
    data[t + 28], data[t + 29], data[t + 30], data[t + 31] = 0, 0, 0, 0
    data[t + 32], data[t + 33], data[t + 34], data[t + 35] = v[s + 32], v[s + 33], v[s + 34], v[s + 35]
    data[t + 40] = v[s + 40]
end

-- A paint scheme's camo row onto LUT row r of data (width columns): its colors (base, detail, wear: columns 0, 2,
-- 5, 6 RGB) and its camo (camo colors and controls 16-19, camo extra 20 w, camo controls and layer 21, camo tiling
-- 22 w), from source row `key`. Mode, detail layer and controls, metallic, specular, roughness and the other w
-- channels stay the target's (a camo copy, src/schemes.lua; unfitted: the camo is several colors).
local COPY_RGB, COPY_ALL = {0, 2, 5, 6}, {16, 17, 18, 19, 21}
function Recolor.apply_copy(data, width, r, source, key)
    local lut, row = key:match('^(%x+):(%d+)$')
    local spec = lut and source.luts[lut]
    if not spec then error('copy source ' .. tostring(key) .. ' not in the source analysis', 0) end
    local v, s = spec.values, tonumber(row) * spec.width * 4
    local t = r * width * 4
    for _, c in ipairs(COPY_RGB) do
        for ch = 0, 2 do data[t + c * 4 + ch] = v[s + c * 4 + ch] end
    end
    for _, c in ipairs(COPY_ALL) do
        for ch = 0, 3 do data[t + c * 4 + ch] = v[s + c * 4 + ch] end
    end
    data[t + 83], data[t + 91] = v[s + 83], v[s + 91]
end

-- A cape LUT's planned tint rows (rows: {[row] = goal}) in a copy of it: each tint's color fitted alone over its
-- material row as built (built: the material LUT's new spec, or nil: as it is), written to column 3 RGB; column 3 w
-- and every other column (heights, emblem layers, the tint's gradient controls) stay. cape = true: bound to the cape
-- LUT slot (src/engine.lua).
-- One fitted row in stats ({rows, err}: how many, the largest CIEDE2000 error; diagnostics), when given.
local function note_fit(stats, err)
    if not stats or not err or err ~= err or err == math.huge then return end
    stats.rows = stats.rows + 1
    if err > stats.err then stats.err = err end
end

local function build_tints(cape, rows, material, built, transfer, yield, stats)
    local width, height = cape.width, cape.height
    local data = ffi.new('float[?]', width * height * 4)
    ffi.copy(data, cape.values, width * height * 16)
    local values = built and built.data or material.values
    for r, goal in pairs(rows) do
        local t = (r * width + 3) * 4
        local err
        data[t], data[t + 1], data[t + 2], err = transfer.fit_base(values, material.width, r,
            {cape.values[t], cape.values[t + 1], cape.values[t + 2]}, goal)
        note_fit(stats, err)
        yield()
    end
    return {width = width, height = height, data = data, cape = true}
end

-- New LUT data for every target LUT the plan changes: {[lut] = {width, height, data (float array)}}. Each
-- row is the target's own; a planned row keeps its material (or takes its source row's finish, goal.finish: Match
-- Materials, from the source analysis) and takes the colors transfer.apply fits to its desired perceived color, or
-- a paint scheme's camo row copied (goal.copy). A cape's tint rows (target.tint_of: its cape LUT -> material LUT)
-- are fitted after the material rows they tint (build_tints). yield() after each fitted row and inside a fit
-- (src/transfer.lua). stats (optional): {rows, err} gets each fit (diagnostics).
function Recolor.build_luts(target, plan, transfer, yield, source, stats)
    local changed = {}
    for key, goal in pairs(plan) do
        local lut, row = key:match('^(%x+):(%d+)$')
        changed[lut] = changed[lut] or {}
        changed[lut][tonumber(row)] = goal
    end
    local out, tint_of = {}, target.tint_of or {}
    for lut, rows in pairs(changed) do
        if not tint_of[lut] then out[lut] = Recolor.build_lut(target.luts[lut], rows, transfer, yield, source, stats) end
    end
    for lut, rows in pairs(changed) do
        local material = tint_of[lut]
        if material then
            out[lut] = build_tints(target.luts[lut], rows, target.luts[material], out[material], transfer, yield, stats)
        end
    end
    return out
end

-- One material LUT's new data: original (the analysis's {values, width, height}) with its planned rows ({[row] =
-- goal}) recolored; {width, height, data}. stats as build_luts.
function Recolor.build_lut(original, rows, transfer, yield, source, stats)
    local width, height = original.width, original.height
    local data = ffi.new('float[?]', width * height * 4)
    ffi.copy(data, original.values, width * height * 16)
    for r, goal in pairs(rows) do
        if goal.finish then Recolor.apply_finish(data, width, r, source, goal.finish) end
        if goal.copy then
            Recolor.apply_copy(data, width, r, source, goal.copy)
        else
            note_fit(stats, transfer.apply(data, width, r, goal.L, goal.a, goal.b, goal.cal))
        end
        yield()
    end
    return {width = width, height = height, data = data}
end

-- Emblem sheets (KB match-your-colors-cape-tint, round 2). A cape emblem that would no longer read
-- (Matcher.cape_emblems) is recolored in a copy of the cape's decal sheet (Capes.recolor_sheet) bound on the
-- decal_sheet slot of its materials (src/engine.lua DECAL_SLOT, BC3 with its mip chain). A plan keeps only the
-- recipe (sheet_recipe); each job turns it into the sheet's data (sheet_spec: SHEETS_KEPT recipes kept, the original
-- bytes of the last sheet read kept by the pipeline), in buffers outside the Lua heap (the game's LuaJIT keeps every
-- Lua object below 2 GB, shared with the whole game: KB user-crash-report-2026-10-02), freed by the collector once
-- nothing references them (a texture keeps its data). About 5.6 MB per sheet; nothing here runs per frame.
local MALLOC_DECLARED = 'myc1_malloc_declared'
local function c_buffer(size)
    if not pcall(ffi.typeof, MALLOC_DECLARED) then
        ffi.cdef [[
            typedef struct myc1_malloc_declared { int unused; } myc1_malloc_declared;
            void *myc1_malloc(size_t size) __asm__("malloc");
            void myc1_free(void *pointer) __asm__("free");
        ]]
    end
    local raw = ffi.C.myc1_malloc(size)
    if raw == nil then error('no memory for a ' .. size .. '-byte sheet', 0) end
    return ffi.gc(ffi.cast('uint8_t *', raw), ffi.C.myc1_free)
end
Recolor.c_buffer = c_buffer

-- The bytes of a w x h BC3 mip chain of `mips` mips.
local function bc3_bytes(width, height, mips)
    local total = 0
    for m = 0, mips - 1 do
        local w, h = math.max(1, math.floor(width / 2 ^ m)), math.max(1, math.floor(height / 2 ^ m))
        total = total + math.max(1, math.floor((w + 3) / 4)) * math.max(1, math.floor((h + 3) / 4)) * 16
    end
    return total
end

-- A color shift rounded to SHIFT_STEP: the endpoints round to 5-6 bits, and a shift that differs in its last bits
-- (the reference's and the runtime's emblem colors agree to about 1e-12) could move one across a rounding edge.
Recolor.SHIFT_STEP = 1 / 1024
local function step(x) return math.floor(x / Recolor.SHIFT_STEP + 0.5) * Recolor.SHIFT_STEP end

-- The recipe of a cape plan's sheet: {name, width, height, mips, size, cells = {{rect, shift}}} for the emblems that
-- take a color (picks: Matcher.cape_emblems, by emblem index), in emblem order, a cell overlapping an earlier one left
-- out; nil when none takes one or its sheet is not a BC3 sheet.
-- Whether rect overlaps the rect of one of cells.
local function overlaps(cells, rect)
    for _, cell in ipairs(cells) do
        local r = cell.rect
        if rect[1] < r[3] and r[1] < rect[3] and rect[2] < r[4] and r[2] < rect[4] then return true end
    end
    return false
end

function Recolor.sheet_recipe(target, picks)
    local recipe
    for i, e in ipairs(target.emblems or {}) do
        local pick = picks[i]
        if pick and e.rect and e.sheet_format == Recolor.SHEET_FORMAT and (not recipe or recipe.name == e.sheet) then
            recipe = recipe or {name = e.sheet, width = e.sheet_width, height = e.sheet_height, mips = e.sheet_mips,
                                size = bc3_bytes(e.sheet_width, e.sheet_height, e.sheet_mips), cells = {}}
            if not overlaps(recipe.cells, e.rect) then
                recipe.cells[#recipe.cells + 1] = {rect = e.rect, shift = {step(pick.L - e.L), step(pick.a - e.a),
                                                                           step(pick.b - e.b)}}
            end
        end
    end
    return recipe
end

-- A recipe as a string (the sheets kept are keyed by it).
local function sheet_key(recipe)
    local parts = {recipe.name}
    for _, cell in ipairs(recipe.cells) do
        local r, d = cell.rect, cell.shift
        parts[#parts + 1] = string.format('%d,%d,%d,%d:%.9g,%.9g,%.9g', r[1], r[2], r[3], r[4], d[1], d[2], d[3])
    end
    return table.concat(parts, ';')
end

local sheets_kept, sheets_order = {}, {}
-- The sheet data of a recipe (a job's: ctx with p, the pipeline, cape_kit and deps): {sheet = true, width, height,
-- mips, size, data (uint8_t pointer, outside the Lua heap)}, the recolored copy of the cape's sheet; nil and why when
-- the sheet cannot be read. yield() between the steps and inside the recolor.
function Recolor.sheet_spec(ctx, recipe, yield)
    local key = sheet_key(recipe)
    local spec = sheets_kept[key]
    if spec then return spec end
    local original, why = ctx.p.sheet(recipe, ctx.cape_kit.archive)
    if not original then return nil, why end
    local data = c_buffer(recipe.size)
    for at = 0, recipe.size - 1, Recolor.SHEET_CHUNK * 4 do -- about 0.1 ms a piece outside the game
        ffi.copy(data + at, original + at, math.min(Recolor.SHEET_CHUNK * 4, recipe.size - at))
        yield()
    end
    for _, cell in ipairs(recipe.cells) do
        ctx.deps.Capes.recolor_sheet(data, recipe, cell, ctx.deps.Colour, yield)
    end
    spec = {sheet = true, width = recipe.width, height = recipe.height, mips = recipe.mips, size = recipe.size,
            data = data}
    sheets_kept[key], sheets_order[#sheets_order + 1] = spec, key
    if #sheets_order > Recolor.SHEETS_KEPT then sheets_kept[table.remove(sheets_order, 1)] = nil end
    return spec
end

-- A kit analysis's measured appearance for the matcher: {kit = its entry (or nil), row, hoods = its hood rows (or
-- nil)} (matcher v12), or nil without the appearance table. The kit id is a number (game memory) or its 8 hex digits
-- (tests' catalogue).
-- An analysis whose geometry came from a mod's patches (geometry_patched, src/kits.lua) has no measurement: its
-- pixels were counted on the archived units and masks. A kit record whose measurement does not cover its rows' LUTs
-- (a native look a transmog composed onto another record) takes the one measured kit with exactly those LUTs.
local function covers(kit, rows)
    if not kit then return false end
    for _, row in ipairs(rows) do
        if not kit.luts[row.lut] then return false end
    end
    return true
end

function Recolor.look_of(analysis, appearance)
    if not appearance then return nil end
    if analysis.kit.kit_type == 'Cape' then
        -- not measured (the study hid the cape): its rows fit through the response their cloth borrows, a tint row
        -- through its material row's (tint_of: its cape LUT -> material LUT; src/matcher.lua borrow_rows)
        return {row = appearance.row, borrow = true, tint_of = analysis.tint_of}
    end
    local id = analysis.kit.id
    if type(id) == 'number' then id = string.format('%08x', id) end
    local kit
    if not analysis.geometry_patched then
        kit = appearance.kit(id)
        if not covers(kit, analysis.rows) and appearance.kit_for and #analysis.rows > 0 then
            local luts = {}
            for _, row in ipairs(analysis.rows) do luts[row.lut] = true end
            local found, found_id = appearance.kit_for(luts)
            if found then kit, id = found, found_id end
        end
    end
    return {kit = kit, row = appearance.row, hoods = appearance.hoods and appearance.hoods(id) or nil}
end

-- Degrees between two hues (a, b pairs), 0-180.
local function hue_apart(a1, b1, a2, b2)
    local d = math.abs(math.deg(math.atan2(b1, a1) - math.atan2(b2, a2))) % 360.0
    return d > 180.0 and 360.0 - d or d
end

-- The texel color (sRGB) of a planned pattern: its desired color through the pattern's measured gain (matcher
-- v12: perceived = gain x texel color, linear), else the desired color itself. A gain is measured at the pattern's
-- own color over its own base and does not hold far from them: the B-01 Tactical's yellow stripes asked for the
-- IX-VOIDWALKER's navy got a grey-green texel (hue 167 degrees, the navy's -99) and showed grey-green (rendered check
-- 2026-10-07). When the texel would turn more than 60 degrees (src/transfer.lua TINT_HUE) from the desired hue, or
-- the desired color is near-neutral (chroma < 5, src/matcher.lua NEUTRAL_TINT_C), the gain's luminance alone scales
-- it: its hue kept, a neutral kept neutral (research/match12.py pattern_color).
function Recolor.pattern_texel(goal, colour)
    if not goal.gain then return colour.lab_to_srgb(goal.L, goal.a, goal.b) end
    local r, g, b = colour.lab_to_linear(goal.L, goal.a, goal.b)
    local to_srgb = colour.linear_to_srgb
    local g1, g2, g3 = math.max(goal.gain[1], 1e-4), math.max(goal.gain[2], 1e-4), math.max(goal.gain[3], 1e-4)
    local tr, tg, tb = to_srgb(r / g1), to_srgb(g / g2), to_srgb(b / g3)
    local _, ta, tb_ = colour.srgb_to_lab(tr, tg, tb)
    if math.sqrt(goal.a * goal.a + goal.b * goal.b) >= 5.0 and hue_apart(ta, tb_, goal.a, goal.b) <= 60.0 then
        return tr, tg, tb
    end
    local luma = math.max(g1 * 0.2126 + g2 * 0.7152 + g3 * 0.0722, 1e-4)
    return to_srgb(r / luma), to_srgb(g / luma), to_srgb(b / luma)
end

-- New pattern textures for every target pattern the pattern plan changes: {[pattern] = {width, height, data}}:
-- the target's own texels with texel 0's color set to the planned color in sRGB (Recolor.pattern_texel; its mask
-- layer, the controls of texels 1-2 kept). colour: the Colour module.
function Recolor.build_patterns(target, plan, colour)
    local out = {}
    for name, goal in pairs(plan) do
        local original = target.luts[name]
        local count = original.width * original.height
        local data = ffi.new('float[?]', count * 4)
        ffi.copy(data, original.values, count * 16)
        data[0], data[1], data[2] = Recolor.pattern_texel(goal, colour)
        out[name] = {width = original.width, height = original.height, data = data}
    end
    return out
end

-- An analysis' patterns for the matcher: {{pattern, area, r, g, b (texel 0)}, ...}.
function Recolor.patterns_of(analysis)
    local out = {}
    for _, p in ipairs(analysis.patterns or {}) do
        local texture = analysis.luts[p.pattern]
        if texture then
            local v = texture.values
            out[#out + 1] = {pattern = p.pattern, area = p.area, r = v[0], g = v[1], b = v[2]}
        end
    end
    return out
end

-- The game's kit catalogue (customization manager [game + 0x33264F8]: kit pointers at +0, count at +8):
-- find(id) -> kit (src/kits.lua read_kit), its record read again on every call (a job's three): a transmog mod
-- recomposes a record at runtime under the same id (its carrier, KB match-your-colors-review-transmog-v13), and the
-- kit kept is replaced when the record lists anything else. signature(id): the record's content now (no catalogue
-- scan, no pause; nil before the first lookup). The first lookup reads every kit's id (one read each); a miss reads
-- them again once (kits loaded later).
local function catalogue(memory, game, Kits, yield)
    local u8p = 'const uint8_t *'
    local function read(address, size, out) return memory.read_into(ffi.cast(u8p, address), size, out) end
    local function u64(b, o)
        return (b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216) + (b[o + 4] + b[o + 5] * 256) * HIGH
    end
    local addresses, kits = nil, {}
    local buffer = ffi.new('uint8_t[96]')

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

    local self = {}
    function self.find(id)
        if not addresses or not addresses[id] then scan() end
        local address = addresses[id]
        if not address then error(string.format('kit %08x not in the catalogue', id), 0) end
        local kit, why = Kits.read_kit(read, address, buffer)
        if not kit then error(why, 0) end
        local known = kits[id]
        if known and Kits.signature(known) == Kits.signature(kit) then return known end
        kits[id] = kit
        return kit
    end

    function self.signature(id)
        local address = addresses and addresses[id]
        local kit = address and Kits.read_kit(read, address, buffer)
        return kit and Kits.signature(kit) or nil
    end
    return self
end

-- The pipeline (created on the first job): the shared samples, color model, texture caches, analyses, plans
-- and the kit catalogue, kept for the session (well under 1 MB plus about 10 KB per kit), the index of the installed
-- mods' patch files (src/patches.lua, read once), and the disk cache of analyses and shared samples
-- (src/cache.lua). The game-data reader and its buffers (index head, chunk tables, decoding buffers: several MB)
-- exist only while a job reads game files: open() before reading, close() when the job ends. deps: {Files, Slim,
-- Patches, Texture, Colour, Transfer, Kits, memory, game, Cache, cache_path, build ({exe_sha256, game_sha256}),
-- data_folder and patch_folder (tests only: UTF-8 paths; patch_folder defaults to the data folder)}.
local function pipeline(deps, yield)
    local Files, Slim, Texture, Colour, Kits = deps.Files, deps.Slim, deps.Texture, deps.Colour, deps.Kits
    local self = {analyses = {}, plans = {}, kits = catalogue(deps.memory, deps.game, Kits, yield), reads = 0,
                  bytes = 0, longest = 0, longest_size = 0, cached = {}, order = {}, dirty = false}
    local job = {texture = Texture, yield = yield} -- what the loaders read: reader, buffers, find

    -- A file adapter on the game's data folder (tests name it), or with for_patches on the folder holding the
    -- patches.
    local function data_files(for_patches, clock)
        if for_patches and deps.patch_folder then return Files.new(deps.patch_folder, nil, clock, deps.wait) end
        local folder, count = deps.data_folder, nil
        if not folder then folder, count = Files.game_data_folder() end
        return Files.new(folder, count, clock, deps.wait)
    end

    -- The installed mods' patches, indexed on first use (once per session: the game loaded them at boot).
    local function patches()
        if self.patch_index == nil then
            local types = {Kits.TYPE_TEXTURE, Kits.TYPE_MATERIAL, Kits.TYPE_UNIT}
            self.patch_index = deps.Patches and deps.Patches.index(data_files(true), types, Slim.grower(4096), yield)
                or false
            local index = self.patch_index
            self.patch_status = index and string.format('%d patch files hold %d textures, materials or units the mod '
                .. 'reads (%d unreadable)', #index.patches, index.entries, index.skipped) or nil
        end
        return self.patch_index or nil
    end

    -- The slim index's chunk count and size (they change with any update of the game data) and the signature of
    -- the installed mods' patches.
    local function data_signature()
        local files = data_files(false)
        local handle = files.open('bundles.nxa')
        local head = ffi.new('uint8_t[32]')
        local ok, why = pcall(files.read, handle, 0, 32, head)
        files.close(handle)
        if not ok then error(why, 0) end
        local u32 = function(o) return head[o] + head[o + 1] * 256 + head[o + 2] * 65536 + head[o + 3] * 16777216 end
        local index = patches()
        return string.format('%d:%.0f:%s', u32(8), u32(16) + u32(20) * HIGH, index and index.signature or 'none')
    end

    -- The disk cache (deps.Cache, deps.cache_path, deps.build): analyses made in earlier sessions. A missing,
    -- older or damaged file leaves the cache empty; cache_status says which.
    if deps.Cache and deps.cache_path then
        self.header = deps.Cache.header(deps.build, data_signature())
        local text = deps.Cache.read(deps.cache_path, yield)
        if text then
            -- order: or why it is not used; decoding pauses between entries (a full file is about 1.4 MB)
            local entries, order, samples = deps.Cache.decode(text, self.header, yield)
            if entries then
                self.cached, self.order, self.samples = entries, order, samples
                self.cache_status = string.format('%d kit analyses loaded', #order)
            else
                self.cache_status = 'not used (' .. tostring(order) .. ')'
            end
        else
            self.cache_status = 'none yet'
        end
    end

    -- Moves key to the front of the use order (the file keeps the most recently used analyses).
    function self.touch(key)
        for i, k in ipairs(self.order) do
            if k == key then table.remove(self.order, i) break end
        end
        table.insert(self.order, 1, key)
    end

    -- Writes the cache when jobs made new analyses: true, or false and why. yield (optional): pauses between
    -- entries while the text is built (src/addon.lua runs the save as its own sliced job); the use order is copied
    -- first, as recolor jobs may run while the save is paused.
    function self.save(yield)
        if not self.dirty or not self.header then return true end
        local all, order = {}, {}
        for k, v in pairs(self.cached) do all[k] = v end
        for k, v in pairs(self.analyses) do
            if v then all[k] = v end -- false: a cape that could not be analysed
        end
        for i, key in ipairs(self.order) do order[i] = key end
        self.dirty = false
        return deps.Cache.write(deps.cache_path, deps.Cache.encode(self.header, all, order, self.samples, yield), yield)
    end

    function self.open()
        if job.slim then return end
        self.files = data_files(false, deps.memory.time)
        job.slim = Slim.open(self.files, '', yield)
        local index = patches()
        if index then -- the mods' resources first, as the game loads them
            self.patch_files = deps.patch_folder and data_files(true, deps.memory.time) or self.files
            job.slim = deps.Patches.over(job.slim, index, self.patch_files)
        end
        job.scratch, job.big_scratch = Slim.grower(65536), Slim.grower(Texture.COVERAGE_BLOCK)
        if not self.samples then
            self.samples = Kits.shared_samples(job.slim, Texture, job.scratch, yield)
            if not self.samples then error('shared customization archive not found', 0) end
            self.dirty = true -- the cache file keeps the samples
        end
        if not self.deps then
            self.deps = {yield = yield, textures = Kits.textures(job), colour = self.model(), Kits = Kits,
                         Texture = Texture, Colour = Colour}
        end
        self.deps.slim, self.deps.scratch, self.deps.big_scratch = job.slim, job.scratch, job.big_scratch
    end

    -- The color model and the transfer over the shared samples (from the cache file, else the game files).
    function self.model()
        if not self.samples then self.open() end
        if not self.colour then
            local samples = self.samples
            self.colour = Colour.new(samples.detail, samples.detail_layers, samples.camo, samples.camo_layers)
            self.transfer = deps.Transfer.new(Colour, self.colour, yield) -- pauses inside each row's fit
        end
        return self.colour, self.transfer
    end

    -- Closes the game files and drops the reader and its buffers (the garbage collector frees them).
    function self.close()
        if not job.slim then return end
        local files = self.files
        self.reads, self.bytes = self.reads + files.reads, self.bytes + files.bytes
        self.waits = (self.waits or 0) + files.waits
        if files.longest > self.longest then self.longest, self.longest_size = files.longest, files.longest_size end
        pcall(job.slim.close)
        job.slim, job.scratch, job.big_scratch, job.find = nil, nil, nil, nil
        if self.deps then self.deps.slim, self.deps.scratch, self.deps.big_scratch, self.deps.find = nil, nil, nil, nil end
        self.files, self.patch_files = nil, nil
    end

    -- A paint scheme's m_weapon LUT (src/schemes.lua), read from its archive once per session: a copy whose rows
    -- have their metallic bias and detail metallic controls (column 6 w, column 7) cleared, as a scheme row is paint
    -- (on weapons the bias only shows worn metal on edges).
    self.schemes = {}
    function self.scheme_lut(scheme)
        local found = self.schemes[scheme.lut]
        if found then return found end
        self.open()
        self.find_in(scheme.archive)
        local lut = self.deps.textures.lut(scheme.lut)
        if not lut then error('paint scheme ' .. scheme.id .. ' not in the game data', 0) end
        local values = ffi.new('float[?]', lut.width * lut.height * 4)
        ffi.copy(values, lut.values, lut.width * lut.height * 16)
        for r = 0, lut.height - 1 do
            local t = r * lut.width * 4
            for i = 27, 31 do values[t + i] = 0 end
        end
        found = {values = values, width = lut.width, height = lut.height}
        self.schemes[scheme.lut] = found
        return found
    end

    -- A cape's decal sheet (recipe: Recolor.sheet_recipe's), its whole mip chain (DDS order) in a buffer outside the
    -- Lua heap, read in SHEET_CHUNK pieces with a pause after each; the last sheet read is kept for the session. nil
    -- and why when it is not found or no longer the BC3 sheet the recipe was made for.
    function self.sheet(recipe, archive)
        local kept = self.kept_sheet
        if kept and kept.name == recipe.name then return kept.data end
        self.open()
        self.find_in(archive)
        local found, record = self.deps.find(recipe.name, Kits.TYPE_TEXTURE)
        if not found then return nil, 'decal sheet ' .. recipe.name .. ' not found' end
        local size = job.slim.part_size(record, 'main')
        local main = job.scratch(size)
        job.slim.part(found, record, 'main', 0, size, main, 0)
        local info = Texture.describe(main, size)
        if info.format ~= Recolor.SHEET_FORMAT or info.width ~= recipe.width or info.height ~= recipe.height
            or info.mips ~= recipe.mips or info.total ~= recipe.size then
            return nil, 'decal sheet ' .. recipe.name .. ' is not the sheet analysed'
        end
        local data = c_buffer(info.total)
        local pixels = Texture.pixels(job.slim, found, record, info)
        for at = 0, info.total - 1, Recolor.SHEET_CHUNK do
            pixels(at, math.min(Recolor.SHEET_CHUNK, info.total - at), data, at)
            yield()
        end
        self.kept_sheet = {name = recipe.name, data = data}
        return data
    end

    -- find searches the current kit's archive, then the shared one (set per analysis).
    -- find searches the current kit's archive, then the shared one (set per analysis); a patched resource it serves
    -- (its record names a patch file) is noted in self.touched while an analysis runs.
    function self.find_in(archive)
        local archives, slim = {archive, self.samples.archive}, job.slim
        self.searched = archives
        local function find(name, kind)
            for _, candidate in ipairs(archives) do
                local record = slim.locate(candidate, name, kind)
                if record then
                    if record.file and self.touched then self.touched[candidate .. ' ' .. name .. ' ' .. kind] = record end
                    return candidate, record
                end
            end
            return nil
        end
        self.deps.find, job.find = find, find
    end

    -- The archived (unpatched) LUT `name` in the searched archives, or nil: what a mod's LUT is compared with.
    function self.original_lut(name)
        local base = job.slim and job.slim.base
        if not base then return nil end
        for _, archive in ipairs(self.searched or {}) do
            local record = base.locate(archive, name, Kits.TYPE_TEXTURE)
            if record then
                local ok, values, width, height = pcall(function()
                    local size = base.part_size(record, 'main')
                    local main = job.scratch(size)
                    base.part(archive, record, 'main', 0, size, main, 0)
                    local info = Texture.describe(main, size)
                    return Texture.lut(Texture.pixels(base, archive, record, info), info, job.scratch)
                end)
                if ok then return {values = values, width = width, height = height} end
                return nil
            end
        end
        return nil
    end

    -- What a new analysis read from mods' patches: its marks (src/kits.lua mark_patched) and the content hash of each
    -- patched resource (patch_deps), so a cached copy is checked against the patches when first used.
    function self.after_analysis(made)
        local touched = self.touched or {}
        self.touched = nil
        if not made or next(touched) == nil then return made end
        if made.kit.kit_type ~= 'Cape' then Kits.mark_patched(made, touched, self.original_lut, self.deps.colour) end
        made.patch_deps = {}
        for key, record in pairs(touched) do
            local archive, name, kind = key:match('^(%S+) (%S+) (%S+)$')
            made.patch_deps[#made.patch_deps + 1] = {archive = archive, name = name, kind = kind,
                hash = deps.Patches.content_hash(self.patch_files, record, job.scratch, yield)}
        end
        table.sort(made.patch_deps, function(x, y) return x.archive .. x.name .. x.kind < y.archive .. y.name .. y.kind end)
        return made
    end

    -- Whether a cached analysis still holds: every patched resource it read has the same content now (checked once
    -- per session; an equal-size replacement of an ID mask or unit changes no signature, src/patches.lua).
    local checked = {}
    function self.current(key, analysis)
        local list = analysis.patch_deps
        if not list or #list == 0 then return true end
        if checked[key] ~= nil then return checked[key] end
        local index = patches()
        self.check_files = self.check_files or data_files(true, deps.memory.time)
        local scratch = Slim.grower(deps.Patches.CHUNK)
        local ok = index ~= nil
        for _, d in ipairs(list) do
            local record = ok and deps.Patches.record(index, d.archive, d.name, d.kind)
            ok = record and deps.Patches.content_hash(self.check_files, record, scratch, yield) == d.hash or false
            if not ok then break end
        end
        checked[key] = ok
        return ok
    end
    return self
end

-- The item a job's plans match against, made once per job: the paint scheme's (src/schemes.lua) or the source
-- analysis's; and what Recolor.build_luts copies finishes and camo from. ctx: {deps, p (the pipeline), request,
-- scheme, source (the source analysis)}.
local function source_item(ctx)
    if ctx.s then return ctx.s, ctx.source_luts end
    local deps, p = ctx.deps, ctx.p
    if ctx.scheme then
        local lut = p.scheme_lut(ctx.scheme)
        local colour = p.model()
        ctx.s = deps.Schemes.item(deps.Matcher, deps.Colour, colour, ctx.scheme, lut)
        ctx.source_luts = {luts = {[ctx.scheme.lut] = lut}}
    else
        local source = ctx.source
        ctx.s = deps.Matcher.item(source.rows, source.kit.kit_type == deps.Kits.ARMOR, Recolor.patterns_of(source),
                                  Recolor.look_of(source, deps.Appearance))
        ctx.source_luts = source
    end
    return ctx.s, ctx.source_luts
end

-- A target's LUTs and patterns planned against the job's source item, into made.
local function plan_target(ctx, target, made, yield)
    local deps, request = ctx.deps, ctx.request
    local Matcher = deps.Matcher
    yield() -- the analyses just made leave garbage: a collector step may land here
    local s, source = source_item(ctx)
    yield() -- building a matcher item is up to about 0.15 ms outside the game, a plan about 0.1 ms
    local t = Matcher.item(target.rows, target.kit.kit_type == deps.Kits.ARMOR, Recolor.patterns_of(target),
                           Recolor.look_of(target, deps.Appearance), request.keep_hoods)
    yield()
    ctx.state.stage = 'color transfer'
    local _, transfer = ctx.p.model()
    local plan = Matcher.plan(t, s, request.materials)
    if target.zones then -- a cape's design zones readable
        local _, outcomes = Matcher.cape_zones(plan, t, s, target.zones, target.tint_of)
        made.zones = outcomes
    end
    if target.emblems and #target.emblems > 0 then -- its emblem-sheet layers readable (their sheet cells recolored)
        local picks, outcomes = Matcher.cape_emblems(plan, t, s, target.emblems, target.tint_of)
        made.emblems, made.sheet = outcomes, Recolor.sheet_recipe(target, picks)
    end
    yield()
    made.fits = made.fits or {rows = 0, err = 0}
    for name, spec in pairs(Recolor.build_luts(target, plan, transfer, yield, source, made.fits)) do
        made.luts[name] = spec
    end
    for name, spec in pairs(Recolor.build_patterns(target, Matcher.pattern_plan(t, s), deps.Colour)) do
        made.patterns[name] = spec
    end
end

-- The plan of `targets` under key, made once (plans are kept for the session).
local function planned(ctx, key, targets, yield)
    local made = ctx.p.plans[key]
    ctx.state.stage = 'plan'
    if not made then
        made = {luts = {}, patterns = {}}
        for _, target in ipairs(targets) do plan_target(ctx, target, made, yield) end
        ctx.p.plans[key] = made
    end
    return made
end

-- The options part of a plan's key.
local function options_key(request)
    return table.concat({request.helmet, request.armor, request.body, request.keep_hoods and 1 or 0,
                         request.materials and 1 or 0}, ':')
end

-- A short checksum of kit records' content (src/kits.lua signature): plans are kept per key, and a record a transmog
-- recomposes under the same id must not be given its old plan.
local function records_sum(Kits, ...)
    local a, b = 1, 0
    for _, kit in ipairs({...}) do
        local text = Kits.signature(kit)
        for i = 1, #text do
            a = (a + text:byte(i)) % 65521
            b = (b + a) % 65521
        end
    end
    return string.format('%08x', b * 65536 + a)
end

-- A plan's key: the request's options and the records it was made of.
local function plan_key(ctx)
    return options_key(ctx.request) .. ':' .. ctx.records
end

-- A paint scheme on both items (src/schemes.lua): helmet and armor each planned against the scheme's source item,
-- their LUTs and patterns together in one result for slots 0-9. h, a: the analyses.
local function scheme_job(ctx, h, a, yield)
    local key = 'scheme:' .. ctx.scheme.id .. ':' .. plan_key(ctx)
    local made = planned(ctx, key, {h, a}, yield)
    return {action = 'apply', key = key, luts = made.luts, patterns = made.patterns, first = 0, last = 9, target = h,
            targets = {h, a}}
end

-- The pair: the mode's target item planned against the other, for the mode's slots.
local function pair_job(ctx, h, a, yield)
    local request = ctx.request
    local target = request.mode == Recolor.ARMOR_FROM_HELMET and a or h
    local key = request.mode .. ':' .. plan_key(ctx)
    local made = planned(ctx, key, {target}, yield)
    local slots = SLOTS[request.mode]
    return {action = 'apply', key = key, luts = made.luts, patterns = made.patterns, first = slots[1],
            last = slots[2], target = target}
end

-- The development log line of a cape's plan (made: planned's, with zones and fits): its tint's share, what the zone
-- rule did, the emblem-sheet layers left in their colors and the fits' largest error (reviewer, 2026-10-07: report
-- unhandled layers and remaining error).
local function cape_report(ctx, c, made)
    local tint = 0
    for _, row in ipairs(c.rows) do
        if c.tint_of and c.tint_of[row.lut] then tint = tint + row.area end
    end
    local z, fits = made.zones or {picked = 0, kept = 0, lost = 0}, made.fits or {rows = 0, err = 0}
    local e = made.emblems or {picked = 0, lost = 0}
    local kept = #(c.emblems or {}) - e.picked - e.lost
    return string.format('Cape %08x: tint %.0f%% of it%s; design zones: %d recolored to stay readable, %d kept their '
        .. 'colors, %d unreadable; emblems: %d recolored to stay readable%s, %d unreadable, %d in their own colors; %d '
        .. 'rows fitted (largest error dE %.1f).', ctx.request.cape, tint * 100,
        c.tint_note and (' (no tint modelled: ' .. c.tint_note .. ')') or '', z.picked, z.kept, z.lost, e.picked,
        made.sheet_note and (' (sheet not recolored: ' .. made.sheet_note .. ')') or '', e.lost, kept, fits.rows,
        fits.err)
end

-- Recolor Cape: the cape (src/capes.lua) planned against the job's source item; its LUT joins result (in a new
-- table: plans are kept), its analysis the targets and slot 1 the slot range. Without a cape analysis the result
-- stays as it is.
local function with_cape(ctx, result, yield)
    local c = ctx.cape
    if not c then return result end
    -- the catalogue's record (ctx.cape_kit): an analysis read from the disk cache keeps no piece list
    local key = result.key .. ':cape:' .. string.format('%08x', ctx.request.cape) .. ':'
        .. records_sum(ctx.deps.Kits, ctx.cape_kit)
    local made = planned(ctx, key, {c}, yield)
    local luts, targets = {}, {}
    for name, spec in pairs(result.luts) do luts[name] = spec end
    for name, spec in pairs(made.luts) do luts[name] = spec end
    if made.sheet then -- the sheet's data per job (plans keep only its recipe)
        ctx.state.stage = 'emblem sheet'
        local spec, why = Recolor.sheet_spec(ctx, made.sheet, yield)
        if spec then luts[made.sheet.name] = spec else made.sheet_note = why end
    end
    made.report = made.report or cape_report(ctx, c, made)
    for _, target in ipairs(result.targets or {result.target}) do targets[#targets + 1] = target end
    targets[#targets + 1] = c
    return {action = 'apply', key = key, luts = luts, patterns = result.patterns, first = math.min(result.first, 1),
            last = math.max(result.last, 1), target = result.target or c, targets = targets, cape_report = made.report}
end

-- The analysis of a kit for the request's body: from the session, the disk cache or the game files (a cape through
-- src/capes.lua); nil when it cannot be made (a cape whose LUT is missing).
-- A new analysis of kit from the game files (and mods' patches), with what it read from patches marked.
local function analyse_new(deps, state, p, kit, body)
    state.stage = 'opening the game data'
    p.open()
    state.stage = string.format('analysing kit %08x', kit.id)
    p.touched = {}
    p.find_in(kit.archive)
    local made = kit.kit_type == 'Cape' and deps.Capes.analyse(kit, body, p.deps)
        or (kit.kit_type ~= 'Cape' and deps.Kits.analyse(kit, body, p.deps))
    return p.after_analysis(made)
end

local function analyser(deps, state, request)
    local p = state.pipeline
    return function(kit)
        local key = deps.Cache and deps.Cache.key(kit, request.body) or (kit.id .. ':' .. request.body)
        if p.analyses[key] == nil then
            if p.cached[key] and p.current(key, p.cached[key]) then
                p.analyses[key] = p.cached[key]
            else
                local made = analyse_new(deps, state, p, kit, request.body)
                p.analyses[key] = made or false
                p.dirty = p.dirty or made ~= nil and made ~= false
            end
        end
        if deps.Cache and p.analyses[key] then p.touch(key) end
        return p.analyses[key] or nil
    end
end

-- The helmet's and armor's part of a job: nothing for a complete set (it keeps its colors; only its cape takes
-- them), else the scheme's or the mode's plan.
local function items_job(ctx, set, h, a, yield)
    if set then
        return {action = 'apply', key = 'set:' .. ctx.request.mode .. ':' .. plan_key(ctx), luts = {},
                patterns = {}, first = 1, last = 1, targets = {}}
    end
    if ctx.scheme then return scheme_job(ctx, h, a, yield) end
    return pair_job(ctx, h, a, yield)
end

-- The job: from a request {mode, keep_sets, keep_hoods, materials, scheme, helmet, armor, body, capes, cape} to
-- {action = 'restore' | 'apply', key, luts, patterns, first, last, target (analysis), targets (every target
-- analysis)}. keep_hoods: Recolor Hoods off (the target's hood rows keep their colors); materials: Match Materials
-- on; scheme: a paint scheme (1-11, src/schemes.lua; 0 or nil none), which recolors both items whatever the mode and
-- complete-set option; capes: Recolor Cape on, cape: the cape kit (src/capes.lua), recolored to the same source
-- (the scheme, else the mode's source item; a complete set left alone still gives its cape its colors). Runs inside
-- a coroutine; yield() pauses when the budget is spent.
function Recolor.job(deps, state, request, yield)
    local scheme = deps.Schemes and deps.Schemes.get(request.scheme or 0)
    if request.mode == Recolor.OFF and not scheme then return {action = 'restore', reason = 'off'} end
    state.stage = 'kit catalogue' -- before the pipeline, which reads the catalogue (a job's first slices)
    state.pipeline = state.pipeline or pipeline(deps, yield)
    local p = state.pipeline
    local helmet, armor = p.kits.find(request.helmet), p.kits.find(request.armor)
    local analysis = analyser(deps, state, request)
    local ctx = {deps = deps, p = p, state = state, request = request, scheme = scheme,
                 records = records_sum(deps.Kits, helmet, armor)}
    if request.capes and (request.cape or 0) ~= 0 and deps.Capes then
        ctx.cape_kit = p.kits.find(request.cape)
        ctx.cape = analysis(ctx.cape_kit)
    end
    local set = not scheme and request.keep_sets and helmet.name_upper == armor.name_upper
    if set and not ctx.cape then return {action = 'restore', reason = 'complete set'} end
    local h, a = analysis(helmet), analysis(armor)
    ctx.source = request.mode == Recolor.ARMOR_FROM_HELMET and h or a
    local result = with_cape(ctx, items_job(ctx, set, h, a, yield), yield)
    -- what the kit records listed: src/addon.lua binds a respawn's units to this result only while they still do
    local signature = deps.Kits.signature
    result.signatures = {[helmet.id] = signature(helmet), [armor.id] = signature(armor)}
    if ctx.cape then result.signatures[ctx.cape_kit.id] = signature(ctx.cape_kit) end
    return result
end

-- The target pieces by unit position: {['type:slot'] = entry} for spawned, non-skin pieces with materials, over
-- every target analysis (a paint scheme has two: helmet and armor).
local function piece_index(targets, body)
    local out = {}
    for _, target in ipairs(targets) do
        for _, entry in ipairs(target.pieces) do
            local piece = entry.piece
            local spawned = piece.body == body or piece.body == 3 or target.kit.kit_type == 'Helmet'
            local key = piece.type .. ':' .. piece.slot
            if spawned and not entry.skin and #entry.materials > 0 and not out[key] then out[key] = entry end
        end
    end
    return out
end

-- The runtime textures both controllers use, kept and refilled instead of made and destroyed per plan.
-- take(spec) -> texture: a free texture of the spec's size refilled with its data (update_buffer, no wait), else a
-- new one plus POOL_SPARES free ones made in the same frame; nil and why when the engine gives none.
-- give(texture): back among the free ones; callers give a texture RETIRE_FRAMES frames after its last binding was
-- undone, so no frame in flight still draws with it. deps: {Engine, native, memory}.
function Recolor.pool(deps)
    local Engine, native, memory = deps.Engine, deps.native, deps.memory
    local POINTER = ffi.typeof('const uint8_t *')
    local small = ffi.new('uint8_t[16]')
    local free = {} -- [width * 65536 + height] = {texture, ...}; decal sheets under 'sheet:<width>x<height>'
    local self = {made = 0, refilled = 0, destroyed = 0}

    local function read(address, size, out) return memory.read_into(ffi.cast(POINTER, address), size, out) end
    local function list_for(width, height, sheet)
        local key = sheet and ('sheet:' .. width .. 'x' .. height) or width * 65536 + height
        local list = free[key]
        if not list then
            list = {}
            free[key] = list
        end
        return list
    end
    local function make(spec)
        local texture, why
        if spec.sheet then
            texture, why = Engine.create_texture(native, {width = spec.width, height = spec.height, data = spec.data,
                                                          format = Engine.BC3, mips = spec.mips, size = spec.size}, read,
                                                 small)
            if texture then texture.sheet = true end
        else
            texture, why = Engine.create_texture(native, spec, read, small)
        end
        if texture then self.made = self.made + 1 end
        return texture, why
    end

    function self.take(spec)
        local list = list_for(spec.width, spec.height, spec.sheet)
        local texture = list[#list]
        if texture then
            list[#list] = nil
            Engine.update_texture(native, texture, spec.data)
            self.refilled = self.refilled + 1
            return texture
        end
        local made, why = make(spec)
        if not made then return nil, why end
        for _ = 1, spec.sheet and 0 or Recolor.POOL_SPARES do
            local spare = make(spec)
            if not spare then break end
            list[#list + 1] = spare
        end
        return made
    end

    function self.give(texture)
        local list = list_for(texture.width, texture.height, texture.sheet)
        if #list >= (texture.sheet and Recolor.POOL_MAX_FREE_SHEETS or Recolor.POOL_MAX_FREE) then
            native.destroy(texture.handle)
            self.destroyed = self.destroyed + 1
            return
        end
        list[#list + 1] = texture
    end

    -- How many free textures the pool holds.
    function self.free()
        local count = 0
        for _, list in pairs(free) do count = count + #list end
        return count
    end
    return self
end

-- The bindings controller. deps: {Engine, Avatar, memory, native, pool (Recolor.pool)}.
function Recolor.controller(deps)
    local Engine, Avatar, memory, native, pool = deps.Engine, deps.Avatar, deps.memory, deps.native, deps.pool
    local small, big = ffi.new('uint8_t[16]'), ffi.new('uint8_t[1024]')
    local self = {bindings = {}, textures = {}, retired = {}, key = nil, applied = 0, restored = 0, released = 0,
                  probes = 0}

    -- Reads at address numbers; one pointer object per address is made once and kept (bounded), so the
    -- periodic check allocates nothing.
    local POINTER = ffi.typeof('const uint8_t *')
    local pointers, cached = {}, 0
    local function read(address, size, out)
        local p = pointers[address]
        if not p then
            if cached >= 1024 then pointers, cached = {}, 0 end
            p = ffi.cast(POINTER, address)
            pointers[address], cached = p, cached + 1
        end
        return memory.read_into(p, size, out)
    end

    -- One tracked binding per runtime texture, checked by check().
    local probes = {}
    local function rebuild_probes()
        probes = {}
        local seen = {}
        for _, b in ipairs(self.bindings) do
            if not seen[b.texture] then
                seen[b.texture] = true
                probes[#probes + 1] = b
            end
        end
        self.probes = #probes
    end

    -- False when the game put a material's original LUT (or pattern) back while its unit lives (the caller applies
    -- again): one probe per call, in turn (two reads; alive() only on such a mismatch), so a check costs the same
    -- whatever the number of runtime textures; each texture is checked every #probes calls.
    local turn = 0
    function self.check()
        local count = #probes
        if count == 0 then return true end
        turn = turn % count + 1
        local b = probes[turn]
        local bound = Engine.binding(read, b.material, b.slot, small, big)
        return not (bound == b.vanilla and native.alive(b.unit) ~= 0)
    end

    local function commit(meshes)
        for mesh in pairs(meshes) do native.commit(mesh) end
    end

    -- Puts the vanilla texture back on every tracked material of a live unit; forgets all bindings and
    -- retires every current texture.
    function self.restore(frame)
        local meshes = {}
        for _, b in ipairs(self.bindings) do
            if native.alive(b.unit) ~= 0 and Engine.binding(read, b.material, b.slot, small, big) == b.texture then
                Engine.bind(native, b.material, b.slot, b.vanilla)
                meshes[b.mesh] = true
                self.restored = self.restored + 1
            end
        end
        commit(meshes)
        for _, texture in pairs(self.textures) do
            texture.retired_at = frame
            self.retired[#self.retired + 1] = texture
        end
        self.bindings, self.textures, self.key, self.result = {}, {}, nil, nil
        rebuild_probes()
    end

    -- Gives retired textures back to the pool RETIRE_FRAMES frames after they were retired. Returns how many remain.
    function self.collect(frame)
        local keep = {}
        for _, texture in ipairs(self.retired) do
            if frame - texture.retired_at >= Recolor.RETIRE_FRAMES then
                pool.give(texture)
                self.released = self.released + 1
            else
                keep[#keep + 1] = texture
            end
        end
        self.retired = keep
        return #keep
    end

    -- Drops the bindings of dead units (alive() once per unit). The current plan's textures stay until the plan
    -- changes (a respawn binds the new units to them). Called after an apply and after a unit change.
    function self.prune()
        local live, dead = {}, false
        for _, b in ipairs(self.bindings) do
            if live[b.unit] == nil then
                live[b.unit] = native.alive(b.unit) ~= 0
                dead = dead or not live[b.unit]
            end
        end
        if not dead then return end
        local keep = {}
        for _, b in ipairs(self.bindings) do
            if live[b.unit] then keep[#keep + 1] = b end
        end
        self.bindings = keep
        rebuild_probes()
    end

    -- The runtime texture for one planned LUT or pattern (specs: result.luts or result.patterns), taken from the
    -- pool on first use.
    local function texture_for(specs, name)
        local texture = self.textures[name]
        if texture then return texture end
        local made, why = pool.take(specs[name])
        if not made then error('texture for ' .. name .. ': ' .. why, 0) end
        self.textures[name] = made
        return made
    end

    -- {vanilla texture object -> name} for the planned LUTs or patterns.
    local function vanilla_objects(specs)
        local out = {}
        for name in pairs(specs or {}) do
            local object = Engine.texture_object(native, name)
            if object then out[object] = name end
        end
        return out
    end

    -- Binds the planned texture to slot `slot` of material m when its vanilla texture is one the plan changes;
    -- true when it bound.
    local function bind_slot(u, m, slot, specs, vanilla)
        local bound = Engine.binding(read, m.material, slot, small, big)
        local name = bound and vanilla[bound]
        if not name then return false end
        local texture = texture_for(specs, name)
        Engine.bind(native, m.material, slot, texture.object)
        self.bindings[#self.bindings + 1] = {unit = u.unit, mesh = m.mesh, material = m.material, slot = slot,
                                             vanilla = bound, texture = texture.object}
        return true
    end

    -- Binds the planned textures to every target unit's materials whose LUT (or pattern) the plan changes. A
    -- unit already bound keeps its binding. Returns how many bindings were made now.
    -- Binds one unit's materials (vanilla: {luts, patterns} objects by name; the pattern slot is read only when
    -- the plan changes a pattern, the cape LUT slot only on the cape's unit (slot 1) when the plan changes its tint);
    -- marks the meshes to commit. Returns how many bindings were made.
    local function bind_unit(result, u, vanilla, meshes)
        local slots = {{Engine.LUT_SLOT, result.luts, vanilla.luts}}
        if vanilla.any_pattern then slots[#slots + 1] = {Engine.PATTERN_SLOT, result.patterns, vanilla.patterns} end
        if u.slot == 1 then -- the cape's unit: its tint and its emblems' sheet
            if vanilla.any_tint then slots[#slots + 1] = {Engine.CAPE_LUT_SLOT, result.luts, vanilla.luts} end
            if vanilla.any_sheet then slots[#slots + 1] = {Engine.DECAL_SLOT, result.luts, vanilla.luts} end
        end
        local count = 0
        for _, m in ipairs(Engine.unit_materials(native, u.unit)) do
            for _, s in ipairs(slots) do
                if bind_slot(u, m, s[1], s[2], s[3]) then
                    meshes[m.mesh], count = true, count + 1
                end
            end
        end
        return count
    end

    -- Whether any planned texture is of a kind (field: 'cape', a cape LUT copy, Recolor.build_luts; 'sheet', a decal
    -- sheet copy, Recolor.sheet_spec).
    local function any_of(luts, field)
        for _, spec in pairs(luts) do
            if spec[field] then return true end
        end
        return false
    end

    local function bind_units(result, identity, slot)
        local vanilla = {luts = vanilla_objects(result.luts), patterns = vanilla_objects(result.patterns)}
        vanilla.any_pattern = next(vanilla.patterns) ~= nil
        vanilla.any_tint, vanilla.any_sheet = any_of(result.luts, 'cape'), any_of(result.luts, 'sheet')
        local pieces = piece_index(result.targets or {result.target}, identity.body)
        local meshes, count = {}, 0
        for _, u in ipairs(Avatar.units(memory, identity, slot, result.first, result.last)) do
            if pieces[u.type .. ':' .. u.slot] then count = count + bind_unit(result, u, vanilla, meshes) end
        end
        commit(meshes)
        return count
    end

    -- Applies a job result: a new plan puts the vanilla textures back first; the same plan only binds units
    -- that are still vanilla (a respawn, a new preview).
    function self.apply(result, identity, slot, frame)
        if result.action == 'restore' then
            self.restore(frame)
            return 0
        end
        if self.key ~= result.key then self.restore(frame) end
        self.key, self.result = result.key, result
        local count = bind_units(result, identity, slot)
        self.prune()
        rebuild_probes()
        self.applied = self.applied + count
        return count
    end
    return self
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Recolor.apply_finish, Recolor.apply_copy, note_fit, build_tints, Recolor.build_luts,
        Recolor.build_lut, cape_report, c_buffer, bc3_bytes, step, overlaps, Recolor.sheet_recipe, sheet_key,
        Recolor.sheet_spec,
        hue_apart, Recolor.pattern_texel,
        Recolor.build_patterns, Recolor.look_of, source_item, plan_target, planned, options_key, scheme_job, pair_job,
        with_cape, analyse_new, analyser, items_job, covers, records_sum, plan_key,
        Recolor.patterns_of, catalogue, pipeline,
        Recolor.job, piece_index, Recolor.pool, Recolor.controller}) do
        jit.off(fn, true)
    end
end

return Recolor
