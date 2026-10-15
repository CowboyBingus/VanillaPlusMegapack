-- Match Your Colors: the engine calls that recolor, verified live on Steam build 25480438.
--
-- Script C API [game.dll + 0x3326308]: Unit (+24) alive +1824, num_meshes +424, mesh +440; Mesh (+232)
-- num_materials +8, material +24, commit +32; Material (+40) set_resource +128. get_engine_api (exe 0xa4e50):
-- 26 = RenderBufferApi (create_buffer +0x60, update_buffer +0x68, destroy_buffer +0x70, lookup_resource +0x78),
-- 5 = ResourceManagerApi (can_get_by_id +0x30, get_by_id +0x40). Every function address is compared with its
-- expected executable offset once per session, before any call.
--
-- A material keeps its texture bindings at +24 (count) / +32 (array of {u32 slot, pointer}); the LUT slot is
-- 0x7e662968, the pattern slot 0x81d4c49d (the piece's 3 x 1 pattern texture, research/ref/lut.frag). A runtime
-- LUT or pattern is an RGBA32F texture (23 x N or 3 x 1 texels) of one mip. The engine keeps pointers into its
-- data and the render thread reads them later, so the data stays referenced while the texture holds it.
--
-- Creating a texture is slow: for a texture view create_buffer (exe 0x1c7cc0) queues the creation, then inserts a
-- "render fence" and waits on it (0x105e40, 0x106030), so the game's main thread stops until the render thread
-- has worked through everything queued before it, about one frame (the Armory hitch of v1.1: one 7-15 ms frame
-- per recolor). update_buffer (0x1c8090) only queues new data in the renderer's update context, which the frame
-- kick (0x10a5c0) hands to the render thread before the frame that draws with it: no wait. Textures are made
-- updatable (validity 1) and refilled (src/recolor.lua's pool). Nothing here runs on an idle frame.
local ffi = require('ffi')

local Engine = {}

local SENTINEL = 'myc1_engine_declared'
local DECLARATIONS = [[
    typedef struct myc1_engine_declared { int unused; } myc1_engine_declared;
    typedef uint8_t (*myc1_unit_alive)(uint32_t unit);
    typedef uint32_t (*myc1_unit_meshes)(uint32_t unit);
    typedef uint64_t (*myc1_unit_mesh)(uint32_t unit, uint32_t index);
    typedef uint32_t (*myc1_mesh_materials)(uint64_t mesh);
    typedef uint64_t (*myc1_mesh_material)(uint64_t mesh, uint32_t index);
    typedef void (*myc1_mesh_commit)(uint64_t mesh);
    typedef void (*myc1_material_set_resource)(uint64_t material, uint32_t slot, uint64_t resource);
    typedef uint64_t (*myc1_get_engine_api)(uint32_t id);
    typedef uint32_t (*myc1_buffer_create)(uint32_t size, uint32_t validity, uint32_t view_type, const void *view,
                                            const void *data);
    typedef void (*myc1_buffer_update)(uint32_t handle, uint32_t size, const void *data);
    typedef void (*myc1_buffer_destroy)(uint32_t handle);
    typedef uint64_t (*myc1_buffer_resource)(uint32_t handle);
    typedef uint8_t (*myc1_resource_can_get)(uint64_t type, uint64_t name);
    typedef uint64_t (*myc1_resource_get)(uint64_t type, uint64_t name);
]]

Engine.SCRIPT_API_RVA = 0x3326308
Engine.GET_ENGINE_API_RVA = 0xa4e50
Engine.GET_ENGINE_API_PREFIX = '\72\131\236\40\131\249\1\15\133' -- sub rsp, 28h; cmp ecx, 1; jnz
Engine.LUT_SLOT = 0x7e662968
Engine.PATTERN_SLOT = 0x81d4c49d
Engine.CAPE_LUT_SLOT = 0x0e494183 -- 'cape_lut' (the cape shader's __tex_cape_lut, t2: KB match-your-colors-cape-tint)
Engine.DECAL_SLOT = 0x632a8b80 -- 'decal_sheet' (the cape shader's __tex_decal_sheet, t9: the emblems' colors)
Engine.TEXTURE_TYPE = 0xCD4238C6A0C69E32ULL
Engine.RGBA32F = 0x80820820
-- RenderBufferApi's compressed formats are 0x10000000 + n (compressed_format +0x08 = exe 0x1c7480); its format table
-- (exe 0x190c840, 8 bits per texel for n = 2) gives BC1, BC2, BC3, BC4, BC5, BC6H, BC7 for n = 0-6. A BC3 sheet with
-- its full mip chain (DDS order) made and bound on a cape live (2026-10-07, research/live/live_emblem_probe.py).
Engine.BC3 = 0x10000002
-- BC1 (n = 0 in the table above; a mod's albedo of gear without a color table, src/albedo.lua, v1.5): made, bound and
-- refilled live (2026-10-14: the Cowboy Hat's unchanged bytes render as the mod's own texture, research/live/
-- live_v15_tickets.py; refilled copies as made ones, live_v15_hatrefill.py), its slot the material's albedo ('albedo',
-- 0xac652e43).
Engine.BC1, Engine.ALBEDO_SLOT = 0x10000000, 0xac652e43
Engine.TEXTURE_VIEW = 3
Engine.UPDATABLE = 1 -- create_buffer's validity: the texture takes update_buffer
-- {table, slot offset, expected executable offset} for every function the mod calls.
Engine.FUNCTIONS = {
    alive = {'unit', 1824, 0x1feeb0}, meshes = {'unit', 424, 0x200cd0}, mesh = {'unit', 440, 0x200d20},
    materials = {'mesh', 8, 0x344300}, material = {'mesh', 24, 0x344350}, commit = {'mesh', 32, 0x344360},
    set_resource = {'material', 128, 0x30f2b0}, -- a jump to 0x4f3230
    create = {'buffers', 0x60, 0x1c7cc0}, update = {'buffers', 0x68, 0x1c8090}, destroy = {'buffers', 0x70, 0x1c81a0},
    resource = {'buffers', 0x78, 0x1c8670},
    can_get = {'resources', 0x30, 0xa0d30}, get = {'resources', 0x40, 0xa0df0},
}
local TYPES = {alive = 'myc1_unit_alive', meshes = 'myc1_unit_meshes', mesh = 'myc1_unit_mesh',
               materials = 'myc1_mesh_materials', material = 'myc1_mesh_material', commit = 'myc1_mesh_commit',
               set_resource = 'myc1_material_set_resource', create = 'myc1_buffer_create',
               update = 'myc1_buffer_update', destroy = 'myc1_buffer_destroy', resource = 'myc1_buffer_resource',
               can_get = 'myc1_resource_can_get', get = 'myc1_resource_get'}
local SCRIPT_TABLES = {unit = 24, mesh = 232, material = 40}
local ENGINE_APIS = {buffers = 26, resources = 5}
local HIGH = 4294967296
local MAX_MESHES, MAX_MATERIALS, MAX_BINDINGS = 64, 64, 64

-- A pointer for bingus_memory's reads (which take pointers) from an address number.
local function at(address) return ffi.cast('const uint8_t *', address) end
Engine.at = at

-- The engine functions, or nil and why. memory: bingus_memory's api (read, read_into); game, exe: module
-- bases as numbers; get_api: tests only (the engine's get_engine_api otherwise).
function Engine.open(memory, game, exe, get_api)
    if not ffi.abi('64bit') then return nil, 'Windows x64 required' end
    if not pcall(ffi.typeof, SENTINEL) then ffi.cdef(DECLARATIONS) end
    local cell = ffi.new('uint8_t[16]')
    local function u64(address)
        if not memory.read_into(at(address), 8, cell) then return nil end
        local low = cell[0] + cell[1] * 256 + cell[2] * 65536 + cell[3] * 16777216
        local high = cell[4] + cell[5] * 256 + cell[6] * 65536 + cell[7] * 16777216
        return low + high * HIGH
    end
    if memory.read(at(exe + Engine.GET_ENGINE_API_RVA), #Engine.GET_ENGINE_API_PREFIX) ~= Engine.GET_ENGINE_API_PREFIX then
        return nil, 'get_engine_api changed'
    end
    local tables = {}
    local script = u64(game + Engine.SCRIPT_API_RVA)
    if not script or script < 0x10000 then return nil, 'script API unavailable' end
    for name, offset in pairs(SCRIPT_TABLES) do tables[name] = u64(script + offset) end
    get_api = get_api or ffi.cast('myc1_get_engine_api', exe + Engine.GET_ENGINE_API_RVA)
    for name, id in pairs(ENGINE_APIS) do
        local found = get_api(id)
        tables[name] = found ~= 0 and tonumber(found) or nil
    end
    local self = {calls = 0}
    for name, spec in pairs(Engine.FUNCTIONS) do
        local base = tables[spec[1]]
        local address = base and u64(base + spec[2])
        if address ~= exe + spec[3] then return nil, 'engine function changed: ' .. name end
        self[name] = ffi.cast(TYPES[name], address)
    end
    return self
end

-- A 64-bit resource name from 16 hex digits, as uint64 cdata.
function Engine.name64(hex)
    local high, low = tonumber(hex:sub(1, 8), 16), tonumber(hex:sub(9, 16), 16)
    return ffi.cast('uint64_t', high) * 4294967296ULL + low
end

-- The loaded texture object of a texture resource name, or nil when it is not loaded.
function Engine.texture_object(native, hex)
    local name = Engine.name64(hex)
    if native.can_get(Engine.TEXTURE_TYPE, name) == 0 then return nil end
    local object = native.get(Engine.TEXTURE_TYPE, name)
    if object == 0 then return nil end
    return tonumber(object)
end

-- Every material of a live unit: {{mesh, material}, ...} (numbers), at most 64 x 64.
function Engine.unit_materials(native, unit)
    local out = {}
    if native.alive(unit) == 0 then return out end
    local meshes = math.min(native.meshes(unit), MAX_MESHES)
    for m = 0, meshes - 1 do
        local mesh = native.mesh(unit, m)
        if mesh ~= 0 then
            local count = math.min(native.materials(mesh), MAX_MATERIALS)
            for j = 0, count - 1 do
                local material = native.material(mesh, j)
                if material ~= 0 then out[#out + 1] = {mesh = tonumber(mesh), material = tonumber(material)} end
            end
        end
    end
    return out
end

-- A material's texture bindings read into big (16 bytes each: the slot u32 at +0, the texture object at +8): how many,
-- or nil. read(address number, size, buffer) -> true; buffer: >= 16 bytes, big: >= 64 x 16 bytes.
function Engine.bindings(read, material, buffer, big)
    if not read(material + 24, 16, buffer) then return nil end
    local count = buffer[0] + buffer[1] * 256 + buffer[2] * 65536 + buffer[3] * 16777216
    local array = (buffer[8] + buffer[9] * 256 + buffer[10] * 65536 + buffer[11] * 16777216)
        + (buffer[12] + buffer[13] * 256) * HIGH
    if count == 0 or count > MAX_BINDINGS or array < 0x10000 then return nil end
    if not read(array, count * 16, big) then return nil end
    return count
end

-- The texture object bound to `slot` among the count bindings in big (Engine.bindings), or nil. An entry's low byte
-- is compared first: most are other slots, and this runs interpreted (one index of big instead of four; the apply
-- spent a fifth of its time decoding slots, harness profile 2026-10-11).
function Engine.binding_in(big, count, slot)
    local low = slot % 256
    for i = 0, count - 1 do
        local o = i * 16
        if big[o] == low and big[o] + big[o + 1] * 256 + big[o + 2] * 65536 + big[o + 3] * 16777216 == slot then
            return (big[o + 8] + big[o + 9] * 256 + big[o + 10] * 65536 + big[o + 11] * 16777216)
                + (big[o + 12] + big[o + 13] * 256) * HIGH
        end
    end
    return nil
end

-- The texture object bound to a material's texture slot (Engine.LUT_SLOT, Engine.PATTERN_SLOT,
-- Engine.CAPE_LUT_SLOT), or nil. Arguments as Engine.bindings.
function Engine.binding(read, material, slot, buffer, big)
    local count = Engine.bindings(read, material, buffer, big)
    if not count then return nil end
    return Engine.binding_in(big, count, slot)
end

-- A runtime texture, updatable: {handle, object, data, view, width, height, format, mips, size}. spec: {width,
-- height, data, format, mips, size}: a LUT is RGBA32F of one mip (data: width x height x 4 floats; format, mips and
-- size left out); a cape's decal sheet copy is BC3 with its mip chain (format Engine.BC3, mips, size: its bytes, mips
-- in DDS order: create_buffer takes the mip count from view[6] and each mip's bytes from the format). data is kept
-- referenced. Waits for the render thread (see above). Returns nil and why when the engine gives no render handle.
function Engine.create_texture(native, spec, read, buffer)
    local width, height, data = spec.width, spec.height, spec.data
    local format, mips = spec.format or Engine.RGBA32F, spec.mips or 1
    local size = spec.size or width * height * 16
    local view = ffi.new('uint32_t[14]')
    view[0], view[1], view[2], view[3], view[4], view[5], view[6] = format, 0, width, height, 1, 1, mips
    local handle = native.create(size, Engine.UPDATABLE, Engine.TEXTURE_VIEW, view, data)
    local object = tonumber(native.resource(handle))
    if not object or object == 0 or not read(object, 4, buffer) then
        native.destroy(handle)
        return nil, 'no texture object'
    end
    local render = buffer[0] + buffer[1] * 256 + buffer[2] * 65536
    if render == 0xFFFFFF then
        native.destroy(handle)
        return nil, 'no render handle'
    end
    return {handle = handle, object = object, data = data, view = view, width = width, height = height,
            format = format, mips = mips, size = size}
end

-- New data for a runtime texture of the same size and format (queued for the render thread, no wait); the texture
-- keeps `data` referenced while it holds it, and the data it replaces until the pool takes the texture back
-- (pool.give, RETIRE_FRAMES after its last binding): the render thread reads the queued update later, and whether
-- the engine still reads a texture's first data after an update was never measured (a decal sheet refill, v1.5).
function Engine.update_texture(native, texture, data)
    native.update(texture.handle, texture.size or texture.width * texture.height * 16, data)
    texture.previous, texture.data = texture.data, data
end

-- Binds a texture object to a material's texture slot (the mesh is committed by the caller).
function Engine.bind(native, material, slot, object)
    native.set_resource(material, slot, object)
end

Engine.POOL_SPARES = 2 -- free textures made beside one that must be made (that frame waits for the renderer anyway)
Engine.POOL_MAX_FREE = 48 -- free textures kept per size; one more given back is destroyed (a 23 x 8 one is 2.9 KB)
Engine.POOL_MAX_FREE_SHEETS = 1 -- free decal sheet copies kept (5.6 MB each, and their data)
Engine.SHEET_NOTES = 16 -- decal sheet log lines the pool keeps until they are logged
Engine.POOL_MAX_FREE_ALBEDOS = 1 -- free recolored albedos kept (2.8 MB each for a 2048 x 2048 BC1 with its mips)
-- textures of a prepared plan's sizes made ahead, per texture it has (pool.stock): with 4 the harness's stress pass (an
-- armor, a helmet and a cape in turn every 0.05 s in the Armory) still made 9 in an 8.7 ms frame (2026-10-11)
Engine.POOL_STOCK = 6
-- Every LUT size of the game's kits and capes (build 25480438; research/profiling/lut_sizes.lua, MYC_SET=capes for the
-- capes): 23 x 8 every kit's, 23 x 5 most capes' material, 16 x 5 most capes' tint, 3 x 1 patterns; the rest rare.
Engine.POOL_SIZES = {{23, 8}, {23, 7}, {23, 6}, {23, 5}, {23, 4}, {16, 8}, {16, 5}, {16, 3}, {16, 1}, {3, 1}}
-- The runtime textures both controllers use, kept and refilled instead of made and destroyed per plan.
-- reserve(spec, count): an apply's demand of one size made room for first (below). take(spec) -> texture: a free
-- texture of the spec's size refilled with its data (update_buffer, no wait), else a new one plus POOL_SPARES free
-- ones made in the same frame; nil and why when the engine gives none.
-- give(texture): back among the free ones; callers give a texture RETIRE_FRAMES frames after its last binding was
-- undone, so no frame in flight still draws with it (src/recolor.lua RETIRE_FRAMES). deps: {native, memory}.
-- Counters: made, refilled, destroyed, and sheets = {made, refilled}; sheet_notes: a line per decal sheet taken since
-- the caller last cleared it (src/addon.lua logs them with the apply).
-- A free texture's list: LUTs and patterns by size; a decal sheet copy also by its mip count and bytes, so a sheet
-- is only ever refilled with data of its own layout (v1.4 keyed sheets by size alone: a modded sheet of the same
-- size and fewer mips would have been refilled with the old mip chain's byte count).
function Engine.pool_key(t)
    if t.sheet then return 'sheet:' .. t.width .. 'x' .. t.height .. ':' .. (t.mips or 1) .. ':' .. t.size end
    if t.albedo then return 'albedo:' .. (t.bc1 and 'bc1:' or 'bc3:') .. t.width .. 'x' .. t.height .. ':' .. t.size end
    return t.width * 65536 + t.height
end

-- A decal sheet's log line for the pool (src/sheets.lua sheet_spec gives a spec its name, recipe sum and sample).
local function sheet_note(spec, how, over)
    return string.format('Cape sheet %s r%08x d%08x (%d mips, %d bytes): %s%s', tostring(spec.name),
                         spec.recipe_sum or 0, spec.sample or 0, spec.mips or 1, spec.size or 0, how,
                         over and string.format(' over %s r%08x', tostring(over.name), over.recipe_sum or 0) or '')
end

function Engine.pool(deps)
    local native, memory = deps.native, deps.memory
    local POINTER = ffi.typeof('const uint8_t *')
    local small = ffi.new('uint8_t[16]')
    local free = {} -- [Engine.pool_key] = {texture, ...}
    local self = {made = 0, refilled = 0, destroyed = 0, sheets = {made = 0, refilled = 0}, sheet_notes = {}}

    local function read(address, size, out) return memory.read_into(ffi.cast(POINTER, address), size, out) end
    local function list_for(t)
        local key = Engine.pool_key(t)
        local list = free[key]
        if not list then
            list = {}
            free[key] = list
        end
        return list
    end
    -- A decal sheet made or refilled: counted, noted (the last SHEET_NOTES kept until src/addon.lua logs them), and
    -- the texture told which sheet it now holds.
    local function took_sheet(texture, spec, how)
        self.sheets[how] = self.sheets[how] + 1
        local over = how == 'refilled' and {name = texture.sheet_name, recipe_sum = texture.sheet_sum} or nil
        local notes = self.sheet_notes
        if #notes >= Engine.SHEET_NOTES then table.remove(notes, 1) end
        notes[#notes + 1] = sheet_note(spec, how, over)
        texture.sheet_name, texture.sheet_sum = spec.name, spec.recipe_sum
    end
    local function make(spec)
        local texture, why
        if spec.sheet or spec.albedo then -- a block-compressed copy with its mip chain
            texture, why = Engine.create_texture(native, {width = spec.width, height = spec.height, data = spec.data,
                format = spec.bc1 and Engine.BC1 or Engine.BC3, mips = spec.mips, size = spec.size}, read, small)
            if texture then
                texture.sheet, texture.albedo, texture.bc1 = spec.sheet, spec.albedo, spec.bc1
                if spec.sheet then took_sheet(texture, spec, 'made') end
            end
        else
            texture, why = Engine.create_texture(native, spec, read, small)
        end
        if texture then self.made = self.made + 1 end
        return texture, why
    end

    function self.take(spec)
        local list = list_for(spec)
        local texture = list[#list]
        if texture then
            list[#list] = nil
            if texture.data ~= spec.data then -- a spec's data never changes once built: the same buffer, the same texels
                Engine.update_texture(native, texture, spec.data)
                self.refilled = self.refilled + 1
                if spec.sheet then took_sheet(texture, spec, 'refilled') end
            end
            return texture
        end
        local made, why = make(spec)
        if not made then return nil, why end
        for _ = 1, (spec.sheet or spec.albedo) and 0 or Engine.POOL_SPARES do
            local spare = make(spec)
            if not spare then break end
            list[#list + 1] = spare
        end
        return made
    end

    -- Room for `count` textures of spec's size before an apply takes them: when fewer are free, the shortfall plus as
    -- many spares as count (at least POOL_SPARES; a sheet none) are made now. Making a texture waits until the render
    -- thread has worked through its backlog; the makings after it in the same frame find it idle (the audit's Armory
    -- log: 1 texture 7.58 ms, 4 textures 7.49 ms, 3 textures 5.1-5.4 ms). So the frame that must grow covers the next
    -- plan of the same shape too, which is applied while this one is still bound or retiring: v1.3 grew a 9-LUT plan's
    -- size again on the next such plan, a second 5-7 ms frame. A helmet's plan (one texture a size) grows as before.
    function self.reserve(spec, count)
        local list = list_for(spec)
        local free = #list
        if free >= count then return end
        local spares = (spec.sheet or spec.albedo) and 0 or math.max(Engine.POOL_SPARES, count)
        local made = {}
        for _ = 1, count - free + spares do
            local texture = make(spec)
            if not texture then break end -- the engine gives none: take() reports why
            made[#made + 1] = texture
        end
        for i = #made, 1, -1 do list[#list + 1] = made[i] end -- taken in the order made (spec's own data first)
    end

    -- Up to `want` free textures of spec's size (made with spec's data).
    local function fill(spec, want)
        local list = list_for(spec)
        for _ = #list + 1, want do
            local texture = make(spec)
            if not texture then return end
            list[#list + 1] = texture
        end
    end

    -- A plan's sizes in the order met: {{spec, count}, ...}.
    local function sizes_of(result)
        local sizes, order = {}, {}
        for _, kind in ipairs({'luts', 'patterns'}) do
            for _, spec in pairs(result[kind] or {}) do
                local list = list_for(spec)
                local size = sizes[list]
                if not size then
                    size = {spec = spec, count = 0}
                    sizes[list], order[#order + 1] = size, size
                end
                size.count = size.count + 1
            end
        end
        return order
    end

    -- Makes, ahead of an apply, the textures a prepared plan's apply would make (src/addon.lua finish_ahead: while the
    -- game loads, before the Helldiver is made), and more for the plans after it: of each of its sizes STOCK times its
    -- count free (at most POOL_MAX_FREE; a decal sheet copy its count), and of every other LUT size of the game
    -- (POOL_SIZES) POOL_SPARES + 1, made with zeros. Making textures waits for the render thread once per frame: the
    -- first apply on the ship made 20 in a frame of 7.8 ms, Armory browsing more in frames of 4-6 ms, a ship outfit with
    -- a 23 x 7 LUT 3 in 5.1 ms; ahead, while loading, 36 took 1.5 ms (harness profiles 2026-10-11, KB
    -- match-your-colors-stress-test). result: a job's {luts, patterns}. Returns how many it made.
    function self.stock(result)
        local before = self.made
        for _, size in ipairs(sizes_of(result)) do
            fill(size.spec, (size.spec.sheet or size.spec.albedo) and size.count
                 or math.min(size.count * Engine.POOL_STOCK, Engine.POOL_MAX_FREE))
        end
        for _, size in ipairs(Engine.POOL_SIZES) do
            local width, height = size[1], size[2]
            if #list_for({width = width, height = height}) <= Engine.POOL_SPARES then
                fill({width = width, height = height, data = ffi.new('float[?]', width * height * 4)},
                     Engine.POOL_SPARES + 1)
            end
        end
        return self.made - before
    end

    local function max_free(texture)
        if texture.sheet then return Engine.POOL_MAX_FREE_SHEETS end
        return texture.albedo and Engine.POOL_MAX_FREE_ALBEDOS or Engine.POOL_MAX_FREE
    end
    function self.give(texture)
        texture.previous = nil -- RETIRE_FRAMES after its last binding: no queued update reads it any more
        local list = list_for(texture)
        if #list >= max_free(texture) then
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

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Engine.open, Engine.name64, Engine.texture_object, Engine.unit_materials, Engine.bindings,
        Engine.binding_in, Engine.binding, Engine.pool, Engine.pool_key, sheet_note,
        Engine.create_texture, Engine.update_texture, Engine.bind}) do
        jit.off(fn, true)
    end
end

return Engine
