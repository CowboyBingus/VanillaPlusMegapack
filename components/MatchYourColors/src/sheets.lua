-- Match Your Colors: the emblem-sheet copies (moved from src/recolor.lua in v1.5; KB match-your-colors-cape-tint,
-- round 2). Attached to Recolor (Sheets.attach: Recolor.sheet_recipe, sheet_spec, c_buffer and the SHEET constants)
-- before any job runs; src/recolor.lua plans and binds them.
local ffi = require('ffi')

local Sheets = {}

Sheets.SHEETS_KEPT = 2 -- recolored sheets a session keeps ready (the bound one and the next)
Sheets.SHEET_FORMAT = 77 -- DXGI BC3 (src/texture.lua FORMAT_BC3): the decal sheets recolored
Sheets.SHEET_CHUNK = 262144 -- bytes of a sheet read between two pause points

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
Sheets.c_buffer = c_buffer

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
Sheets.SHIFT_STEP = 1 / 1024
local function step(x) return math.floor(x / Sheets.SHIFT_STEP + 0.5) * Sheets.SHIFT_STEP end

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

function Sheets.sheet_recipe(target, picks)
    local recipe
    for i, e in ipairs(target.emblems or {}) do
        local pick = picks[i]
        if pick and e.rect and e.sheet_format == Sheets.SHEET_FORMAT and (not recipe or recipe.name == e.sheet) then
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
-- Every prepared sheet anything still references (a result a controller has bound, the local player's, the preview's
-- or a squadmate's), found again by its recipe before another copy is made: SHEETS_KEPT alone made six 5.6 MB copies
-- for the recipes 1, 2, 3, 1, 2, 3 of three live capes (the audit, rank 6). Weak: it keeps nothing alive.
local sheets_live = setmetatable({}, {__mode = 'v'})

-- key's spec among the kept ones, most recently used last; the oldest past SHEETS_KEPT is let go.
local function keep_sheet(key, spec)
    for i, k in ipairs(sheets_order) do
        if k == key then table.remove(sheets_order, i) break end
    end
    sheets_kept[key], sheets_order[#sheets_order + 1] = spec, key
    if #sheets_order > Sheets.SHEETS_KEPT then sheets_kept[table.remove(sheets_order, 1)] = nil end
end

-- The sheet data of a recipe (a job's: ctx with p, the pipeline, cape_kit and deps): {sheet = true, width, height,
-- mips, size, data (uint8_t pointer, outside the Lua heap)}, the recolored copy of the cape's sheet; nil and why when
-- the sheet cannot be read. yield() between the steps and inside the recolor.
function Sheets.sheet_spec(ctx, recipe, yield)
    local key = sheet_key(recipe)
    local spec = sheets_kept[key] or sheets_live[key]
    if spec then
        keep_sheet(key, spec)
        return spec
    end
    local original, why = ctx.p.sheet(recipe, ctx.cape_kit.archive)
    if not original then return nil, why end
    local data = c_buffer(recipe.size)
    for at = 0, recipe.size - 1, Sheets.SHEET_CHUNK * 4 do -- about 0.1 ms a piece outside the game
        ffi.copy(data + at, original + at, math.min(Sheets.SHEET_CHUNK * 4, recipe.size - at))
        yield()
    end
    for _, cell in ipairs(recipe.cells) do
        ctx.deps.Capes.recolor_sheet(data, recipe, cell, ctx.deps.Colour, yield)
    end
    spec = {sheet = true, width = recipe.width, height = recipe.height, mips = recipe.mips, size = recipe.size,
            data = data, name = recipe.name}
    spec.recipe_sum, spec.sample = ctx.deps.Capes.sheet_sums(key, data, recipe.size)
    sheets_live[key] = spec
    keep_sheet(key, spec)
    return spec
end

-- Recolor's sheet functions and constants (src/recolor.lua calls them through Recolor).
function Sheets.attach(Recolor)
    Recolor.sheet_recipe, Recolor.sheet_spec, Recolor.c_buffer = Sheets.sheet_recipe, Sheets.sheet_spec, Sheets.c_buffer
    Recolor.SHEETS_KEPT, Recolor.SHEET_FORMAT = Sheets.SHEETS_KEPT, Sheets.SHEET_FORMAT
    Recolor.SHEET_CHUNK, Recolor.SHIFT_STEP = Sheets.SHEET_CHUNK, Sheets.SHIFT_STEP
end

-- Runs inside jobs, once per recipe: interpreted.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({c_buffer, bc3_bytes, step, overlaps, Sheets.sheet_recipe, sheet_key, keep_sheet,
        Sheets.sheet_spec, Sheets.attach}) do
        jit.off(fn, true)
    end
end

return Sheets
