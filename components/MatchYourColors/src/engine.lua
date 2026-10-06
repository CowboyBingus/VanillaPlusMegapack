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
Engine.TEXTURE_TYPE = 0xCD4238C6A0C69E32ULL
Engine.RGBA32F = 0x80820820
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

-- The texture object bound to a material's texture slot (Engine.LUT_SLOT, Engine.PATTERN_SLOT), or nil.
-- read(address number, size, buffer) -> true; buffer: >= 16 bytes, big: >= 64 x 16 bytes.
function Engine.binding(read, material, slot, buffer, big)
    if not read(material + 24, 16, buffer) then return nil end
    local count = buffer[0] + buffer[1] * 256 + buffer[2] * 65536 + buffer[3] * 16777216
    local array = (buffer[8] + buffer[9] * 256 + buffer[10] * 65536 + buffer[11] * 16777216)
        + (buffer[12] + buffer[13] * 256) * HIGH
    if count == 0 or count > MAX_BINDINGS or array < 0x10000 then return nil end
    if not read(array, count * 16, big) then return nil end
    for i = 0, count - 1 do
        local o = i * 16
        local at = big[o] + big[o + 1] * 256 + big[o + 2] * 65536 + big[o + 3] * 16777216
        if at == slot then
            return (big[o + 8] + big[o + 9] * 256 + big[o + 10] * 65536 + big[o + 11] * 16777216)
                + (big[o + 12] + big[o + 13] * 256) * HIGH
        end
    end
    return nil
end

-- A runtime LUT texture, updatable: {handle, object, data, view, width, height}; data: float array of width x
-- height x 4 (kept). Waits for the render thread (see above). Returns nil and why when the engine gives no render
-- handle.
function Engine.create_texture(native, width, height, data, read, buffer)
    local view = ffi.new('uint32_t[14]')
    view[0], view[1], view[2], view[3], view[4], view[5], view[6] = Engine.RGBA32F, 0, width, height, 1, 1, 1
    local handle = native.create(width * height * 16, Engine.UPDATABLE, Engine.TEXTURE_VIEW, view, data)
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
    return {handle = handle, object = object, data = data, view = view, width = width, height = height}
end

-- New data for a runtime texture of the same size (queued for the render thread, no wait); the texture keeps
-- `data` referenced while it holds it.
function Engine.update_texture(native, texture, data)
    native.update(texture.handle, texture.width * texture.height * 16, data)
    texture.data = data
end

-- Binds a texture object to a material's texture slot (the mesh is committed by the caller).
function Engine.bind(native, material, slot, object)
    native.set_resource(material, slot, object)
end

-- Code that runs once or rarely (jobs, startup, events) stays interpreted, sub-functions included: it must not
-- add traces to the LuaJIT code cache the game and every mod share. Only the hot loops stay compiled.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Engine.open, Engine.name64, Engine.texture_object, Engine.unit_materials, Engine.binding,
        Engine.create_texture, Engine.update_texture, Engine.bind}) do
        jit.off(fn, true)
    end
end

return Engine
