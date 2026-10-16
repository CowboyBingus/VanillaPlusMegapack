-- Match Your Colors: from the local player's kits to recolored materials.
--
-- A job (a coroutine resumed by the frame step with a time budget) reads the two kits from game memory,
-- analyses them from the game's files (src/kits.lua; kept for the session), plans the match
-- (src/matcher.lua) and builds the new LUT data: each planned row keeps its material and takes fitted colors
-- (src/transfer.lua); a planned pattern (v11.4) is a copy of the pattern texture with texel 0's color replaced.
-- The step then applies it in one frame through the bindings controller (Recolor.controller: src/bindings.lua,
-- attached to Recolor by Bindings.attach before any plan is applied).
local ffi = require('ffi')

local Recolor = {}

Recolor.OFF, Recolor.HELMET_FROM_ARMOR, Recolor.ARMOR_FROM_HELMET = 1, 2, 3
-- a plan's units without materials at its apply are tried again every PENDING_EVERY frames for PENDING_FRAMES
-- (controller settle)
Recolor.PENDING_EVERY, Recolor.PENDING_FRAMES = 4, 120
-- Helmet and Armor Match Cape: both items planned against the worn (or previewed) cape (cape_source_job).
Recolor.CAPE_SOURCE = 4
Recolor.RETIRE_FRAMES = 4
-- The emblem-sheet copies (Recolor.sheet_recipe, sheet_spec, c_buffer, SHEET_FORMAT, SHEET_CHUNK, SHEETS_KEPT) are
-- src/sheets.lua's, attached to Recolor (Sheets.attach) before any job runs.
local SLOTS = {[Recolor.HELMET_FROM_ARMOR] = {0, 0}, [Recolor.ARMOR_FROM_HELMET] = {1, 9}}
local LUT_WIDTH = 23
local HIGH = 4294967296

-- Match Materials: LUT row r of data (width columns) takes the finish of source row `key` ('lut:row' of the source
-- analysis): metallic (column 6 w, clipped to 0-1), no detail metallic controls (column 7: they follow the source's
-- detail and mesh; v1.0's whole-row copies drew chrome specks with them), the source's specular (column 8) and
-- roughness (column 10 x). Mode, detail layer and controls, colors, camo and tiling stay the target's. A cape's tint
-- row (source.tint_of: its cape LUT -> material LUT; a cape as the source) has its material row's finish.
-- A row that was paint (metallic under 0.5) taking a metal finish is at least METAL_ON_PAINT_ROUGH rough, the game's
-- median hard bare-metal roughness (1,083 rows by area: p25 and p50 0.30; research/scratch/v15/metal_rough_survey.lua):
-- the B-22 Model Citizen's mirror chrome (0.10, kept for parts made for it) on the FS-37 Ravager's quilted chest
-- reflected the Armory's lights as a white blotch and sparkle (independent review round 3, 2026-10-14).
Recolor.METAL_ON_PAINT_ROUGH = 0.30
function Recolor.apply_finish(data, width, r, source, key)
    local lut, row = key:match('^(%x+):(%d+)$')
    lut = lut and source.tint_of and source.tint_of[lut] or lut
    local spec = lut and source.luts[lut]
    if not spec then error('finish source ' .. tostring(key) .. ' not in the source analysis', 0) end
    local v, s = spec.values, tonumber(row) * spec.width * 4
    local t = r * width * 4
    local was_paint = data[t + 27] < 0.5
    data[t + 27] = math.min(math.max(v[s + 27], 0), 1)
    data[t + 28], data[t + 29], data[t + 30], data[t + 31] = 0, 0, 0, 0
    data[t + 32], data[t + 33], data[t + 34], data[t + 35] = v[s + 32], v[s + 33], v[s + 34], v[s + 35]
    data[t + 40] = v[s + 40]
    if was_paint and data[t + 27] >= 0.5 then data[t + 40] = math.max(data[t + 40], Recolor.METAL_ON_PAINT_ROUGH) end
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
        if not tint_of[lut] and target.luts[lut] then -- an albedo's clusters: src/albedo.lua plan_specs
            out[lut] = Recolor.build_lut(target.luts[lut], rows, transfer, yield, source, stats)
        end
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
            -- the analysis LUT as the origin of a row left as copied (its own albedo kept: src/transfer.lua starts)
            note_fit(stats, transfer.apply(data, width, r, goal, source, not goal.finish and original or nil))
        end
        yield()
    end
    return {width = width, height = height, data = data}
end

-- A kit analysis's measured appearance for the matcher: {kit = its entry (or nil), row, seen_share, hoods = its hood
-- rows (or nil)} (matcher v12), or nil without the appearance table. The kit id is a number (game memory) or its 8 hex
-- digits (tests' catalogue).
-- An analysis whose geometry came from a mod's patches (geometry_patched, src/kits.lua) has no measurement: its
-- pixels were counted on the archived units and masks. A kit record whose measurement does not cover its rows' LUTs
-- (a native look a transmog composed onto another record) takes the one measured kit with exactly those LUTs.
-- Without a kit the matcher still has what the study knows of each LUT row (its response, row; how much of any kit's
-- view it showed, seen_share): src/matcher.lua unmeasured_rows.
local function covers(kit, rows)
    if not kit then return false end
    for _, row in ipairs(rows) do
        if not kit.luts[row.lut] then return false end
    end
    return true
end

-- An analysis's measured kit (none when its geometry came from patches; a transmog's composed record, the one kit
-- measured with exactly its LUTs) and the id its hood rows are listed under.
local function measured_kit_of(analysis, appearance)
    local id = analysis.kit.id
    if type(id) == 'number' then id = string.format('%08x', id) end
    if analysis.geometry_patched then return nil, id end
    local kit = appearance.kit(id)
    if not covers(kit, analysis.rows) and appearance.kit_for and #analysis.rows > 0 then
        local luts = {}
        for _, row in ipairs(analysis.rows) do luts[row.lut] = true end
        local found, found_id = appearance.kit_for(luts)
        if found then kit, id = found, found_id end
    end
    return kit, id
end

function Recolor.look_of(analysis, appearance, yield)
    -- a weapon's LUTs are in no measurement (the study measured helmets and armors): its rows keep their drawn shares
    if not appearance or analysis.kit.kit_type == 'Weapon' then return nil end
    if analysis.kit.kit_type == 'Cape' then
        -- not measured (the study hid the cape): its rows fit through the response their cloth borrows, a tint row
        -- through its material row's (tint_of: its cape LUT -> material LUT; src/matcher.lua borrow_rows)
        return {row = appearance.row, borrow = true, tint_of = analysis.tint_of}
    end
    local kit, id = measured_kit_of(analysis, appearance)
    -- without a measurement that covers its rows the matcher reads seen_share: its index made here, in pieces
    if not covers(kit, analysis.rows) and appearance.index_seen then appearance.index_seen(yield) end
    return {kit = kit, row = appearance.row, seen_share = appearance.seen_share,
            hoods = appearance.hoods and appearance.hoods(id) or nil}
end
-- A cape's look as the source of Helmet and Armor Match Cape: its colors' goals aim at their look on screen
-- (src/matcher.lua borrow_rows, CAPE_SHADE).
function Recolor.source_look_of(cape, appearance, yield)
    local look = Recolor.look_of(cape, appearance, yield)
    if look then look.seen = true end
    return look
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

-- The pipeline (created on the first job): the shared samples, color model, texture caches, analyses, plans
-- and the kit catalogue, kept for the session (well under 1 MB plus about 10 KB per kit), the index of the installed
-- mods' patch files (src/patches.lua, read once), and the disk cache of analyses and shared samples
-- (src/cache.lua). The game-data reader and its buffers (index head, chunk tables, decoding buffers: several MB)
-- exist only while a job reads game files: open() before reading, close() when the job ends. deps: {Files, Slim,
-- Patches, Texture, Colour, Transfer, Kits, memory, game, Cache, cache_path, build ({exe_sha256, game_sha256}),
-- data_folder and patch_folder (tests only: UTF-8 paths; patch_folder defaults to the data folder)}. state: the job's
-- holder, whose stage names each step of the construction (the first job's log names its longest slice by it).
local function pipeline(deps, yield, state)
    local Files, Slim, Texture, Colour, Kits = deps.Files, deps.Slim, deps.Texture, deps.Colour, deps.Kits
    local self = {analyses = {}, plans = {}, plan_order = {}, kits = Kits.catalogue(deps.memory, deps.game, yield),
                  reads = 0, bytes = 0, longest = 0, longest_size = 0, cached = {}, order = {}, dirty = false}
    local job = {texture = Texture, yield = yield} -- what the loaders read: reader, buffers, find
    local function stage(name) state.stage = name end

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
            local was = state.stage
            stage("indexing mods' patches")
            local types = {Kits.TYPE_TEXTURE, Kits.TYPE_MATERIAL, Kits.TYPE_UNIT}
            self.patch_index = deps.Patches and deps.Patches.index(data_files(true), types, Slim.grower(4096), yield)
                or false
            local index = self.patch_index
            self.patch_status = index and string.format('%d patch files hold %d textures, materials or units the mod '
                .. 'reads (%d unreadable)', #index.patches, index.entries, index.skipped) or nil
            stage(was)
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
        stage('game data signature')
        self.header = deps.Cache.header(deps.build, data_signature())
        stage('reading the analysis cache')
        local text = deps.Cache.read(deps.cache_path, yield)
        if text then
            -- order: or why it is not used; decoding pauses between entries and sample layers (a full file is about
            -- 0.75-1.4 MB)
            stage('decoding the analysis cache')
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
    -- A weapon's analysis is neither saved nor read back (analyser): the cache keeps a piece's material count, not
    -- its materials, and a weapon's binding names each material's LUTs (weapon_luts). A weapon is analysed again each
    -- session (a job of about 10-20 ms of work). The first test build cached them, and its next session failed every
    -- weapons job ("attempt to index local 'm' (a boolean value)", harness trial 2026-10-15).
    function self.save(yield)
        if not self.dirty or not self.header then return true end
        local all, order = {}, {}
        for k, v in pairs(self.cached) do
            if v.kit.kit_type ~= 'Weapon' then all[k] = v end
        end
        for k, v in pairs(self.analyses) do
            if v and v.kit.kit_type ~= 'Weapon' then all[k] = v end -- false: a cape that could not be analysed
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
                         Texture = Texture, Colour = Colour, Albedo = deps.Albedo,
                         weapon_rows = deps.WeaponData and Kits.weapon_rows(deps.WeaponData) or nil}
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
        files.close_later = true -- its handles closed a few a frame (src/files.lua Files.close_some; src/addon.lua)
        if self.patch_files then self.patch_files.close_later = true end
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
    -- A texture's whole mip chain (its first layer, DDS order) in a buffer outside the Lua heap, read in SHEET_CHUNK
    -- pieces with a pause after each, and its description; nil and why when it is not found.
    function self.chain(name, archive)
        self.open()
        self.find_in(archive)
        local found, record = self.deps.find(name, Kits.TYPE_TEXTURE)
        if not found then return nil, name .. ' not found' end
        local size = job.slim.part_size(record, 'main')
        local main = job.scratch(size)
        job.slim.part(found, record, 'main', 0, size, main, 0)
        local info = Texture.describe(main, size)
        local data = Recolor.c_buffer(info.layer_bytes)
        local pixels = Texture.pixels(job.slim, found, record, info)
        for at = 0, info.layer_bytes - 1, Recolor.SHEET_CHUNK do
            pixels(at, math.min(Recolor.SHEET_CHUNK, info.layer_bytes - at), data, at)
            yield()
        end
        return data, info
    end
    function self.sheet(recipe, archive)
        local kept = self.kept_sheet
        if kept and kept.name == recipe.name then return kept.data end
        local data, info = self.chain(recipe.name, archive)
        if not data then return nil, 'decal sheet ' .. info end
        if info.format ~= Recolor.SHEET_FORMAT or info.width ~= recipe.width or info.height ~= recipe.height
            or info.mips ~= recipe.mips or info.total ~= recipe.size then
            return nil, 'decal sheet ' .. recipe.name .. ' is not the sheet analysed'
        end
        self.kept_sheet = {name = recipe.name, data = data}
        return data
    end

    -- find searches the current kit's archive, then the shared one (set per analysis).
    -- find searches the current kit's archive, then the shared one (set per analysis); a patched resource it serves
    -- (its record names a patch file) is noted in self.touched while an analysis runs.
    -- extra: a further archive searched last (a weapon's template scheme, src/weapons.lua Weapons.kit).
    -- extra: one more archive, or a list (a weapon's: its template's and its attachments', src/weapon_data.lua).
    function self.find_in(archive, extra)
        local archives, slim = {archive, self.samples.archive}, job.slim
        for _, more in ipairs(type(extra) == 'table' and extra or {extra}) do archives[#archives + 1] = more end
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

    -- A new analysis starts: the patched resources it finds (touched) and what it reads of them (the reader's ranges,
    -- src/patches.lua Patches.over) are noted until after_analysis.
    function self.begin_analysis()
        self.touched = {}
        if job.slim then job.slim.ranges = {} end
    end

    -- What a new analysis read from mods' patches: its marks (src/kits.lua mark_patched) and, per patched resource it
    -- found, the byte ranges it read and their content hash (patch_deps), so a cached copy is checked against the
    -- patches when first used: only those bytes are read again (a unit's material list, not its mesh).
    function self.after_analysis(made)
        local touched, read = self.touched or {}, job.slim and job.slim.ranges or {}
        self.touched = nil
        if job.slim then job.slim.ranges = nil end
        if not made or next(touched) == nil then return made end
        if made.kit.kit_type ~= 'Cape' then Kits.mark_patched(made, touched, self.original_lut, self.deps.colour) end
        made.patch_deps = {}
        for key, record in pairs(touched) do
            local archive, name, kind = key:match('^(%S+) (%S+) (%S+)$')
            local ranges = read[record]
            made.patch_deps[#made.patch_deps + 1] = {archive = archive, name = name, kind = kind,
                ranges = deps.Patches.ranges_text(ranges),
                hash = deps.Patches.content_hash(self.patch_files, record, job.scratch, yield, ranges)}
        end
        table.sort(made.patch_deps, function(x, y) return x.archive .. x.name .. x.kind < y.archive .. y.name .. y.kind end)
        return made
    end

    -- Whether a cached analysis still holds: the bytes it read of every patched resource are the same now (checked
    -- once per session; two variants of one mod can hold the same entries, src/patches.lua).
    local checked = {}
    function self.current(key, analysis)
        local list = analysis.patch_deps
        if not list or #list == 0 then return true end
        if checked[key] ~= nil then return checked[key] end
        local index = patches()
        self.check_files = self.check_files or data_files(true, deps.memory.time)
        self.check_scratch = self.check_scratch or Slim.grower(65536)
        local ok = index ~= nil
        for _, d in ipairs(list) do
            local record = ok and deps.Patches.record(index, d.archive, d.name, d.kind)
            local ranges = record and deps.Patches.parse_ranges(d.ranges)
            ok = ranges and deps.Patches.content_hash(self.check_files, record, self.check_scratch, yield, ranges)
                == d.hash or false
            if not ok then break end
        end
        checked[key] = ok
        return ok
    end
    return self
end

-- The item a job's plans match against, made once per job: the paint scheme's (src/schemes.lua), the cape's (Helmet
-- and Armor Match Cape: its cloth rows by their areas, each blended with its tint, Capes.source_rows; its emblems as
-- pattern-like colors; identity by the helmet rule, its largest paint) or the source analysis's; and what Recolor.build_luts copies finishes and camo
-- from. ctx: {deps, p (the pipeline), request, scheme, cape_source (the cape's analysis), source (the source
-- analysis)}.
local function source_item(ctx, yield)
    if ctx.s then return ctx.s, ctx.source_luts end
    local deps, p = ctx.deps, ctx.p
    if ctx.scheme then
        local lut = p.scheme_lut(ctx.scheme)
        local colour = p.model()
        ctx.s = deps.Schemes.item(deps.Matcher, deps.Colour, colour, ctx.scheme, lut)
        ctx.source_luts = {luts = {[ctx.scheme.lut] = lut}}
    elseif ctx.cape_source then
        local cape = ctx.cape_source
        ctx.s = deps.Matcher.item(deps.Capes.source_rows(cape, deps.Colour), false,
                                  deps.Capes.emblem_patterns(cape, deps.Colour),
                                  Recolor.source_look_of(cape, deps.Appearance, yield))
        ctx.s.part_guard = deps.Capes.dark_parts_guard -- dark gloves and boots stay dark
        ctx.s.cape_source = true -- a near one-color item splits by material (src/schemes.lua Schemes.plan)
        -- its finishes are cloth (src/transfer.lua dark_finish: a light paint turned dark takes a dark paint's rough)
        ctx.source_luts = {luts = cape.luts, tint_of = cape.tint_of, cloth = true}
    else
        local source = ctx.source
        ctx.s = deps.Matcher.item(source.rows, source.kit.kit_type == deps.Kits.ARMOR, Recolor.patterns_of(source),
                                  Recolor.look_of(source, deps.Appearance, yield))
        ctx.source_luts = source
    end
    return ctx.s, ctx.source_luts
end

-- A weapon's rows the plan paints: its paint, not its bare metal (metallic over 0.5, src/kits.lua lut_row), which keeps
-- its own color and finish as the game's paint schemes keep a weapon's gunmetal rows. Planned whole, a weapon is mostly
-- metal by its drawn shares (the AR-23 Liberator's rail, magazine, muzzle and steel: about half), its metal took the
-- source's identity (tinted steel) and its grey body a darker grey (offline plans 2026-10-15).
function Recolor.weapon_paint(rows)
    local out = {}
    for _, row in ipairs(rows) do
        if not row.metal then out[#out + 1] = row end
    end
    return out
end

-- A weapon's camo template: its camo rows take the source's camo group (camo), colors and pattern.
local function camo_copies(plan, rows, camo)
    for _, row in ipairs(rows) do
        if row.camo then plan[row.key] = {source = camo, kind = 'pair', copy = camo.rep.key} end
    end
end

-- A cape's design zones and emblem-sheet layers, when readable, into the plan (their sheet cells recolored: made.sheet).
local function cape_parts(Matcher, plan, t, s, target, made)
    if target.zones then
        local _, outcomes = Matcher.cape_zones(plan, t, s, target.zones, target.tint_of)
        made.zones = outcomes
    end
    if target.emblems and #target.emblems > 0 then
        local picks, outcomes = Matcher.cape_emblems(plan, t, s, target.emblems, target.tint_of)
        made.emblems, made.sheet = outcomes, Recolor.sheet_recipe(target, picks)
    end
end

-- A target's LUTs and patterns planned against the job's source item, into made.
local function plan_target(ctx, target, made, yield)
    local deps, request = ctx.deps, ctx.request
    local Matcher = deps.Matcher
    yield() -- the analyses just made leave garbage: a collector step may land here
    local s, source = source_item(ctx, yield)
    yield() -- building a matcher item is up to about 0.15 ms outside the game, a plan about 0.1 ms
    local weapon = target.kit.kit_type == 'Weapon'
    local rows = weapon and Recolor.weapon_paint(target.rows) or target.rows
    local t = Matcher.item(rows, target.kit.kit_type == deps.Kits.ARMOR, Recolor.patterns_of(target),
                           Recolor.look_of(target, deps.Appearance, yield), request.keep_hoods)
    t.weapon = weapon -- src/matcher.lua pair_groups: the identity on its largest painted part
    yield()
    ctx.state.stage = 'color transfer'
    local _, transfer = ctx.p.model()
    local plan = deps.Schemes and deps.Schemes.plan(Matcher, ctx.scheme, t, s, request.materials,
        target.kit.kit_type == 'Cape') or Matcher.plan(t, s, request.materials, target.kit.kit_type == 'Cape')
    if weapon and ctx.camo then camo_copies(plan, rows, ctx.camo) end
    cape_parts(Matcher, plan, t, s, target, made)
    yield()
    made.fits = made.fits or {rows = 0, err = 0}
    for name, spec in pairs(Recolor.build_luts(target, plan, transfer, yield, source, made.fits)) do
        made.luts[name] = spec
    end
    for name, spec in pairs(Recolor.build_patterns(target, Matcher.pattern_plan(t, s, plan), deps.Colour)) do
        made.patterns[name] = spec
    end
    if target.albedos or target.unread then -- a mod's gear without a color table (src/albedo.lua)
        made.albedo_report = deps.Albedo.plan_specs(target, plan, made.luts, ctx.p.chain, deps.Colour, yield)
    end
end

-- The plan of `targets` under key, made once and kept, at most PLANS_KEPT plans, the least recently used let go
-- first (a result still bound keeps its own LUTs; a plan let go is made again when asked for). v1.3 kept every plan
-- for the session: browsing pairs in the Armory grows them without bound (about 3 KB a helmet plan, 26 KB an armor's).
Recolor.PLANS_KEPT = 128
local function planned(ctx, key, targets, yield)
    local p = ctx.p
    local made, order = p.plans[key], p.plan_order
    ctx.state.stage = 'plan'
    if made then
        for i = #order, 1, -1 do
            if order[i] == key then table.remove(order, i) break end
        end
    else
        made = {luts = {}, patterns = {}}
        for _, target in ipairs(targets) do plan_target(ctx, target, made, yield) end
        p.plans[key] = made
        if #order >= Recolor.PLANS_KEPT then p.plans[table.remove(order, 1)] = nil end
    end
    order[#order + 1] = key
    return made
end

-- The options part of a plan's key.
local function options_key(request)
    return table.concat({request.helmet, request.armor, request.body, request.keep_hoods and 1 or 0,
                         request.materials and 1 or 0}, ':')
end

-- Each kit's part of records_sum, made once per kit (weak keys; a kit is not changed once read, src/kits.lua
-- signature): its signature's byte sum s and the sum of its running sums t (mod 65521) and its length n. A job keys
-- its plans by up to five such sums, and in game a plan kept from before spent most of its 0.3-0.7 ms job reading
-- signatures byte by byte (harness profile 2026-10-11, KB match-your-colors-stress-test).
local sum_parts = setmetatable({}, {__mode = 'k'})
local function sum_part(Kits, kit)
    local part = sum_parts[kit]
    if part then return part end
    local text = Kits.signature(kit)
    local s, t = 0, 0
    for i = 1, #text do
        s = (s + text:byte(i)) % 65521
        t = (t + s) % 65521
    end
    part = {s, t, #text}
    sum_parts[kit] = part
    return part
end

-- A short checksum of kit records' content (src/kits.lua signature): plans are kept per key, and a record a transmog
-- recomposes under the same id must not be given its old plan. The Adler-32 of the kits' signatures one after the
-- other, from each kit's part: after n bytes of sum s and running sums t from (a, b), a is a + s and b is b + n a + t.
local function records_sum(Kits, ...)
    local a, b = 1, 0
    for _, kit in ipairs({...}) do
        local part = sum_part(Kits, kit)
        a, b = (a + part[1]) % 65521, (b + part[3] * a + part[2]) % 65521
    end
    return string.format('%08x', b * 65536 + a)
end
Recolor.records_sum = records_sum

-- A plan's key: the request's options and the records it was made of.
local function plan_key(ctx)
    return options_key(ctx.request) .. ':' .. ctx.records
end

-- The key of one item's plan against a source that is not the other item (a paint scheme's, or a cape's source):
-- what its plan depends on, the item's kit record, body and the options (a scheme's plan of the helmet does not
-- depend on the armor; v1.3 keyed both items together, so hovering one item re-planned the other).
local function item_key(ctx, source, kit)
    local request = ctx.request
    return table.concat({source, string.format('%08x', kit.id), records_sum(ctx.deps.Kits, kit), request.body,
                         request.keep_hoods and 1 or 0, request.materials and 1 or 0}, ':')
end

-- A source that is not the other item on both items: a paint scheme (src/schemes.lua, source 'scheme:<id>') or the
-- cape (Helmet and Armor Match Cape, 'capesrc:<cape>:<records>'): helmet and armor each planned against the job's
-- source item (a plan each), their LUTs and patterns together in one result for slots 0-9 (an armor LUT of a name both
-- use last, as one plan of both made them). h, a: the analyses.
local function both_job(ctx, source, h, a, yield)
    local key = source .. ':' .. plan_key(ctx)
    local luts, patterns = {}, {}
    for _, item in ipairs({{h, ctx.helmet_kit}, {a, ctx.armor_kit}}) do
        local made = planned(ctx, item_key(ctx, source, item[2]), {item[1]}, yield)
        for name, spec in pairs(made.luts) do luts[name] = spec end
        for name, spec in pairs(made.patterns) do patterns[name] = spec end
    end
    return {action = 'apply', key = key, luts = luts, patterns = patterns, first = 0, last = 9, target = h,
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
            last = slots[2], target = target, albedo_report = made.albedo_report}
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
    -- its plan depends on the cape and its source, the scheme or the mode's source item, not on the item the mode
    -- recolors (v1.3 keyed it by the whole result: a new helmet re-planned an unchanged cape from an unchanged armor)
    local source = 'cape:' .. (ctx.scheme and ('scheme:' .. ctx.scheme.id) or string.format('%d:%08x:%s',
        ctx.request.mode, ctx.source_kit.id, records_sum(ctx.deps.Kits, ctx.source_kit)))
    local made = planned(ctx, item_key(ctx, source, ctx.cape_kit), {c}, yield)
    local luts, targets = {}, {}
    for name, spec in pairs(result.luts) do luts[name] = spec end
    for name, spec in pairs(made.luts) do luts[name] = spec end
    if made.sheet then -- the sheet's data per job (plans keep only its recipe)
        ctx.state.stage = 'emblem sheet'
        local spec, why = Recolor.sheet_spec(ctx, made.sheet, yield)
        if spec then luts[made.sheet.name] = spec else made.sheet_note = why end
    end
    made.report = made.report or ctx.deps.Capes.report(ctx.request.cape, c, made)
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
    p.begin_analysis()
    p.find_in(kit.archive, kit.extra_archive)
    local made = kit.kit_type == 'Cape' and deps.Capes.analyse(kit, body, p.deps)
        or (kit.kit_type ~= 'Cape' and deps.Kits.analyse(kit, body, p.deps))
    return p.after_analysis(made)
end

-- The kit's analysis under key: the cache's while it still holds (never a weapon's: the pipeline's save), else a new
-- one (false when it cannot be made), marking the cache to save.
local function analysis_of(deps, state, p, kit, key, body)
    local cached = p.cached[key]
    if cached and kit.kit_type ~= 'Weapon' and p.current(key, cached) then return cached end
    local made = analyse_new(deps, state, p, kit, body)
    if made and kit.kit_type ~= 'Weapon' then p.dirty = true end -- a weapon's is not saved
    return made or false
end

local function analyser(deps, state, request)
    local p = state.pipeline
    return function(kit)
        local key = deps.Cache and deps.Cache.key(kit, request.body)
            or (kit.id .. ':' .. request.body .. ':' .. (kit.template or '')) -- a weapon's template (src/weapons.lua)
        if p.analyses[key] == nil then p.analyses[key] = analysis_of(deps, state, p, kit, key, request.body) end
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
    if ctx.scheme then return both_job(ctx, 'scheme:' .. ctx.scheme.id, h, a, yield) end
    if ctx.cape_source then return both_job(ctx, ctx.cape_source_key, h, a, yield) end
    if ctx.kit_source then return both_job(ctx, ctx.kit_source_key, h, a, yield) end
    return pair_job(ctx, h, a, yield)
end

-- The job: from a request {mode, keep_sets, keep_hoods, materials, scheme, helmet, armor, body, capes, cape, source_kit
-- (Squadmates' Colors on Your Colors: this player's helmet or armor, the source of both items, kit_source_of)} to
-- {action = 'restore' | 'apply', key, luts, patterns, first, last, target (analysis), targets (every target
-- analysis)}. keep_hoods: Recolor Hoods off (the target's hood rows keep their colors); materials: Match Materials
-- on; scheme: a paint scheme (1 to #Schemes.LIST, src/schemes.lua; 0 or nil none), which recolors both items
-- whatever the mode and complete-set option; capes: Recolor Cape on, cape: the cape kit (src/capes.lua), recolored to
-- the same source (the scheme, else the mode's source item; a complete set left alone still gives its cape its
-- colors); with mode CAPE_SOURCE (Helmet and Armor Match Cape) the cape is instead the source of both items. Runs inside
-- a coroutine; yield() pauses when the budget is spent. A request without kits (no helmet) builds the pipeline alone:
-- {action = 'prepared'} (work ahead of the Helldiver, src/addon.lua).
-- A preview job whose preview moved on meanwhile (src/addon.lua sets request.obsolete) ends at the next of the job's
-- stage boundaries, between whole analyses and before planning: what it finished stays (analyses are kept).
-- Helmet and Armor Match Cape: the worn (or previewed) cape's kit, analysis and plan-key part into ctx; nil when there
-- is no cape or no analysis of it (its LUT outside the archives searched): the items then keep their colors.
local function cape_source_of(ctx, analysis)
    local request, deps = ctx.request, ctx.deps
    if (request.cape or 0) == 0 or not deps.Capes then return nil end
    local kit = ctx.p.kits.find(request.cape)
    if not kit or request.obsolete then return nil end
    ctx.cape_source_kit = kit
    ctx.cape_source = analysis(kit)
    ctx.cape_source_key = string.format('capesrc:%08x:%s', request.cape, records_sum(deps.Kits, kit))
    return ctx.cape_source
end

-- Recolor Cape's kit and analysis into ctx, when the request asks for it.
local function cape_of(ctx, analysis)
    local request = ctx.request
    if not (request.capes and (request.cape or 0) ~= 0 and ctx.deps.Capes) then return end
    ctx.cape_kit = ctx.p.kits.find(request.cape)
    if not request.obsolete then ctx.cape = analysis(ctx.cape_kit) end
end

-- The job's cape into ctx: with Helmet and Armor Match Cape (ctx.cape_mode; a paint scheme still overrides the
-- mode) its source, never a target; else Recolor Cape's target. Returns the job's result when the mode's source is
-- missing (no cape, or no analysis of it: the items keep their colors), else nil.
local function job_capes(ctx, analysis)
    ctx.cape_mode = ctx.request.mode == Recolor.CAPE_SOURCE and not ctx.scheme
    if not ctx.cape_mode then
        cape_of(ctx, analysis)
    elseif not cape_source_of(ctx, analysis) then
        return {action = ctx.request.obsolete and 'obsolete' or 'restore', reason = 'no cape'}
    end
end

-- Squadmates' Colors on Your Colors (src/addon.lua, src/remote.lua request_of: request.source_kit): this player's
-- helmet or armor is the source of both of a squadmate's items, as the cape is with Helmet and Armor Match Cape; its
-- kit, analysis and plan-key part into ctx (not with a scheme or the cape as the source). Returns the job's result when
-- it cannot be analysed (the squadmate's items keep their colors), else nil.
local function kit_source_of(ctx, analysis)
    local request = ctx.request
    if not request.source_kit or ctx.scheme or ctx.cape_mode then return nil end
    local found, kit = pcall(ctx.p.kits.find, request.source_kit) -- find raises for a kit the catalogue lacks
    local made = found and kit and not request.obsolete and analysis(kit)
    if not made then return {action = request.obsolete and 'obsolete' or 'restore', reason = 'no source kit'} end
    ctx.source_kit, ctx.kit_source = kit, made
    ctx.kit_source_key = string.format('kitsrc:%08x:%s', kit.id, records_sum(ctx.deps.Kits, kit))
end

-- Whether Leave Complete Sets keeps the pair as it is (ctx.set): not with a scheme, nor with the cape as the source
-- (the user asked for the cape's colors on whatever they wear), nor with this player's item as the source (Your
-- Colors). Returns the job's result when nothing else needs a job (no cape to recolor), else nil.
local function set_kept(ctx)
    local r = ctx.request
    ctx.set = not ctx.scheme and not ctx.cape_mode and not ctx.kit_source and r.keep_sets
        and ctx.helmet_kit.name_upper == ctx.armor_kit.name_upper
    if ctx.set and not ctx.cape and not r.obsolete then return {action = 'restore', reason = 'complete set'} end
end

-- The helmet's and the armor's analyses; nil when the request became obsolete before one.
local function item_analyses(ctx, analysis)
    local request = ctx.request
    local h = not request.obsolete and analysis(ctx.helmet_kit) or nil
    return h, h and not request.obsolete and analysis(ctx.armor_kit) or nil
end

-- What the kit records listed, on the result: src/addon.lua binds a respawn's units to it only while they still do.
local function signed(ctx, result)
    local signature = ctx.deps.Kits.signature
    result.signatures = {[ctx.helmet_kit.id] = signature(ctx.helmet_kit), [ctx.armor_kit.id] = signature(ctx.armor_kit)}
    if ctx.cape then result.signatures[ctx.cape_kit.id] = signature(ctx.cape_kit) end
    if ctx.cape_source then result.signatures[ctx.cape_source_kit.id] = signature(ctx.cape_source_kit) end
    if ctx.kit_source then result.signatures[ctx.source_kit.id] = signature(ctx.source_kit) end
    return result
end

-- The session's pipeline, made by its first job (or by work ahead of the Helldiver, src/addon.lua).
local function pipeline_of(deps, state, yield)
    state.stage = 'starting' -- the pipeline names its own steps (the session's first job)
    state.pipeline = state.pipeline or pipeline(deps, yield, state)
    return state.pipeline
end

function Recolor.job(deps, state, request, yield)
    local scheme = deps.Schemes and deps.Schemes.get(request.scheme or 0)
    if request.mode == Recolor.OFF and not scheme then return {action = 'restore', reason = 'off'} end
    local p = pipeline_of(deps, state, yield)
    -- no kits: work ahead of the Helldiver, the pipeline alone (src/addon.lua plan_ahead)
    if not request.helmet then return {action = 'prepared'} end
    state.stage = 'kit catalogue'
    local helmet, armor = p.kits.find(request.helmet), p.kits.find(request.armor)
    local analysis = analyser(deps, state, request)
    local ctx = {deps = deps, p = p, state = state, request = request, scheme = scheme,
                 records = records_sum(deps.Kits, helmet, armor), helmet_kit = helmet, armor_kit = armor,
                 source_kit = request.mode == Recolor.ARMOR_FROM_HELMET and helmet or armor}
    local early = job_capes(ctx, analysis) or kit_source_of(ctx, analysis) or set_kept(ctx)
    if early then return early end
    local h, a = item_analyses(ctx, analysis)
    ctx.source = ctx.kit_source or (request.mode == Recolor.ARMOR_FROM_HELMET and h or a)
    local items = a and items_job(ctx, ctx.set, h, a, yield)
    if not items or request.obsolete then return {action = 'obsolete'} end
    return signed(ctx, with_cape(ctx, items, yield))
end

-- Recolor Weapons (v1.5, src/weapons.lua): the weapons' source, as the cape's (with_cape): the paint scheme, the cape
-- (Helmet and Armor Match Cape) or the mode's source item (the armor for Helmet Matches Armor, the helmet for Armor
-- Matches Helmet; a complete set left alone still gives the weapons its colors). Its key part for the plans' keys, or
-- nil and why when it is missing (no cape, or no analysis of it: the weapons keep their colors).
local function weapons_source(ctx, analysis)
    local request, Kits = ctx.request, ctx.deps.Kits
    if ctx.scheme then return 'scheme:' .. ctx.scheme.id end
    if request.mode == Recolor.CAPE_SOURCE then
        if cape_source_of(ctx, analysis) then return ctx.cape_source_key end
        return nil, 'no cape'
    end
    -- the mode's source item, or with Squadmates' Colors on Your Colors this player's (src/addon.lua source_kit)
    local id = request.source_kit or (request.mode == Recolor.ARMOR_FROM_HELMET and request.helmet or request.armor)
    local kit = ctx.p.kits.find(id)
    ctx.source_kit = kit
    ctx.source = not request.obsolete and analysis(kit) or nil
    if not ctx.source then return nil, 'no source' end
    return string.format('%d:%08x:%s', request.mode, kit.id, records_sum(Kits, kit))
end

-- The Armory's preview weapon: its customization composed as the game does (w.ids) into w; false when it cannot be.
local function composed(ctx, w)
    local deps, p = ctx.deps, ctx.p
    if not w.ids or w.copy then return true end
    p.compose_buffer = p.compose_buffer or ffi.new('uint8_t[?]', deps.Weapons.COPY_SPAN)
    local function read_into(address, size, out)
        return deps.memory.read_into(ffi.cast('const uint8_t *', address), size, out)
    end
    return deps.Weapons.compose(deps.Avatar.reader(deps.memory), read_into, deps.game, w, w.ids, p.compose_buffer)
        and true or false
end

-- A weapon's package, the weapon catalogue's (read once per weapon and session), or false.
local function weapon_package(ctx, w)
    local deps, p = ctx.deps, ctx.p
    p.weapon_packages = p.weapon_packages or {}
    if p.weapon_packages[w.name] == nil then
        p.catalogue_buffer = p.catalogue_buffer or ffi.new('uint8_t[?]', 17280)
        local read = deps.Avatar.reader(deps.memory)
        p.weapon_packages[w.name] = deps.Weapons.package(deps.memory, read, deps.game, w.name, p.catalogue_buffer)
            or false
    end
    return p.weapon_packages[w.name]
end

-- The archives searched beside the package: the template's, and each attachment's (a non-default one is not in the
-- weapon's package: the AR-61 Tenderizer's Reflex Sight kept its colors in the control check, 2026-10-15).
local function kit_archives(data, w, template)
    local extra, archives = {template and template.archive or nil}, data.attachment_archive or {}
    for role = 1, 4 do
        local archive = w.attachments[role] and archives[w.attachments[role]]
        if archive then extra[#extra + 1] = archive end
    end
    return extra
end

-- A weapon's kit (src/weapons.lua Weapons.kit) in its package; nil when the catalogue has no package for it.
local function weapon_kit(ctx, w, template)
    local data = ctx.deps.WeaponData or {}
    local package = composed(ctx, w) and weapon_package(ctx, w)
    if not package then return nil end
    local unit = data.unit_of and data.unit_of[w.name]
    return ctx.deps.Weapons.kit(w, package, template, unit, kit_archives(data, w, template))
end

-- The weapons job: from a request {mode, scheme, keep_hoods, materials, helmet, armor, body, cape, weapons = {weapon
-- of src/weapons.lua, ...}} to {action = 'restore' | 'apply', key, luts, patterns, targets (the weapons' analyses),
-- kits}. One plan per weapon against the source (weapons_source), kept as an item's plan is; LUTs two weapons share
-- (the rail of 77 weapons, attachments of one caliber) take the last weapon's plan. Runs inside a coroutine as
-- Recolor.job; a request whose weapons the player no longer holds (request.obsolete) ends at a stage boundary.
-- A weapon is recolored as a paint scheme of its own (user 2026-10-15: "Look at the different camo / color schemes of
-- the weapons ... they completely change the weapons' patterning. These barely change at all"): its material classes
-- are analysed through a scheme's LUTs, as the game paints a weapon with a scheme (its ID masks then draw the scheme's
-- rows), and those rows are planned against the source: the template. A weapon paint scheme as the source (Paint Scheme
-- 1-11) is that scheme itself, the game's own look (native, unplanned); else DESERT's rows (r0-r1 body, r2 cloth, r3 a
-- lighter and r4 a darker detail, r5 and r7 paint, r6 the one metal: the colored schemes paint the steel the default
-- and HELLDIVER keep, the Liberator's rows 5 and 7, 18% of its body), or DESERT CAMO's when the source's colors include a
-- camo of WEAPON_CAMO_SHARE (its camo row and rail then copy the source's camo row: colors and pattern). Recolored only
-- through its own rows (the first build) the Liberator's grey body took a near grey with most outfits, and through
-- HELLDIVER's (the default's twin) one color all over. Every weapon takes it, sidearms and support weapons too (the game
-- offers schemes for primaries only); a material of no scheme class keeps its own rows.
Recolor.WEAPON_TEMPLATE, Recolor.WEAPON_CAMO_TEMPLATE, Recolor.WEAPON_CAMO_SHARE = 'desert', 'desert_camo', 0.15
-- The source's largest camo group of WEAPON_CAMO_SHARE or more (s: a matcher item), or nil.
local function source_camo(s)
    local camo = nil
    for _, g in ipairs(s and s.groups or {}) do
        if g.camo and g.share >= Recolor.WEAPON_CAMO_SHARE and (not camo or g.share > camo.share) then camo = g end
    end
    return camo
end

local function weapon_template(ctx, s)
    local deps = ctx.deps
    local data, Schemes = deps.WeaponData, deps.Schemes
    if not (data and data.schemes and Schemes) then return nil end
    local id, native, camo = Recolor.WEAPON_TEMPLATE, false, nil
    if ctx.scheme and data.schemes[ctx.scheme.id] then
        id, native = ctx.scheme.id, true
    else
        camo = source_camo(s)
        if camo then id = Recolor.WEAPON_CAMO_TEMPLATE end
    end
    for _, scheme in ipairs(Schemes.LIST) do
        if scheme.id == id then
            return {id = id, classes = data.schemes[id], decals = data.decals and data.decals[id],
                    archive = scheme.archive, native = native, camo = camo}
        end
    end
    return nil
end

-- The LUTs a weapon's analysis binds: each material's planned LUT (or, analysed through a template, its template LUT
-- as planned or as it is) under the name of the LUT the game binds there now (entry.bound, else its own), an
-- attachment's with ATTACHMENT appended: 13 weapons' muzzles (the AR-61 Tenderizer's, the SG-8 Punisher's) bind the
-- weapon's own LUT, which a scheme replaces with its weapon class's LUT on the weapon and m_attachments' on the muzzle
-- (keyed by name alone, the muzzle's plan took the weapon too: HELLDIVER's blue light row on the Tenderizer's trigger
-- guard). The controller binds an ATTACHMENT key on attachment units only (Weapons.units).
-- A scheme's decal sheet (material entry.decal: NIGHT's blank sheet) is bound as it is, a game texture, under the
-- name of the material's own sheet ({decal = true, direct = name}: src/bindings.lua binds it, no pooled copy).
Recolor.ATTACHMENT = '|a'
local function template_copy(lut)
    local spec = {width = lut.width, height = lut.height, data = ffi.new('float[?]', lut.width * lut.height * 4)}
    ffi.copy(spec.data, lut.values, lut.width * lut.height * 16)
    return spec
end
-- One piece's materials into luts (a: its analysis; made: the plan or nil).
local function piece_luts(a, entry, made, luts)
    local suffix = entry.piece.slot == 0 and '' or Recolor.ATTACHMENT
    for _, m in ipairs(entry.materials) do
        local spec = made and made.luts[m.lut]
        if not spec and m.bound and a.luts[m.lut] then spec = template_copy(a.luts[m.lut]) end
        if spec and m.lut then luts[(m.bound or m.lut) .. suffix] = spec end
        if m.decal then luts[m.decal.from .. suffix] = {decal = true, direct = m.decal.to} end
    end
end
local function weapon_luts(a, made, luts)
    for _, entry in ipairs(a.pieces) do piece_luts(a, entry, made, luts) end
end

-- One weapon of a weapons job: its kit (with the template when the game paints it), analysis and plan into the
-- job's luts and patterns; the analysis and kit, or nil.
local function weapon_plan(ctx, w, source, template, out, yield)
    local kit = weapon_kit(ctx, w, template)
    local a = kit and ctx.analysis(kit)
    if not a then return nil end
    local made
    if not (kit.template and template.native) then
        ctx.camo = kit.template and template.camo or nil -- plan_target: the template's camo rows copy it
        made = planned(ctx, item_key(ctx, 'weapon:' .. source, kit), {a}, yield)
        ctx.camo = nil
        for name, spec in pairs(made.patterns) do out.patterns[name] = spec end
    end
    weapon_luts(a, made, out.luts)
    return a, kit
end

function Recolor.weapons_job(deps, state, request, yield)
    local scheme = deps.Schemes and deps.Schemes.get(request.scheme or 0)
    if request.mode == Recolor.OFF and not scheme then return {action = 'restore', reason = 'off'} end
    local p = pipeline_of(deps, state, yield)
    state.stage = 'kit catalogue'
    local analysis = analyser(deps, state, request)
    local ctx = {deps = deps, p = p, state = state, request = request, scheme = scheme, analysis = analysis}
    local source, why = weapons_source(ctx, analysis)
    if not source then return {action = request.obsolete and 'obsolete' or 'restore', reason = why} end
    local template = weapon_template(ctx, (source_item(ctx, yield)))
    local out, targets, keys, kits = {luts = {}, patterns = {}}, {}, {}, {}
    for _, w in ipairs(request.weapons or {}) do
        local a, kit = nil, nil
        if not request.obsolete then a, kit = weapon_plan(ctx, w, source, template, out, yield) end
        if a then
            targets[#targets + 1], kits[#kits + 1] = a, kit
            keys[#keys + 1] = w.name .. '/' .. records_sum(deps.Kits, kit)
        end
    end
    if request.obsolete then return {action = 'obsolete'} end
    if #targets == 0 then return {action = 'restore', reason = 'no weapon analysed'} end
    return {action = 'apply', key = 'weapons:' .. source .. ':' .. table.concat(keys, ','), luts = out.luts,
            patterns = out.patterns, first = 0, last = 0, targets = targets, kits = kits}
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Recolor.apply_finish, Recolor.apply_copy, note_fit, build_tints, Recolor.build_luts,
        Recolor.build_lut,
        hue_apart, Recolor.pattern_texel, measured_kit_of, Recolor.weapon_paint,
        Recolor.build_patterns, Recolor.look_of, source_item, camo_copies, cape_parts, plan_target, planned,
        options_key, both_job, pair_job,
        with_cape, analyse_new, analysis_of, analyser, items_job, covers, sum_part, records_sum, plan_key, item_key,
        cape_source_of, kit_source_of,
        cape_of,
        job_capes, set_kept, item_analyses,
        signed,
        Recolor.patterns_of, pipeline, pipeline_of,
        Recolor.job, weapons_source, composed, weapon_package, kit_archives, weapon_kit, source_camo, weapon_template,
        template_copy, piece_luts, weapon_luts, weapon_plan,
        Recolor.weapons_job}) do
        jit.off(fn, true)
    end
end

return Recolor
