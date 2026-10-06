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
local SLOTS = {[Recolor.HELMET_FROM_ARMOR] = {0, 0}, [Recolor.ARMOR_FROM_HELMET] = {1, 9}}
local LUT_WIDTH = 23
local HIGH = 4294967296

-- New LUT data for every target LUT the plan changes: {[lut] = {width, height, data (float array)}}. Each
-- row is the target's own; a planned row keeps its material and takes the colors transfer.apply fits to its
-- desired perceived color. yield() after each fitted row.
function Recolor.build_luts(target, plan, transfer, yield)
    local changed = {}
    for key, goal in pairs(plan) do
        local lut, row = key:match('^(%x+):(%d+)$')
        changed[lut] = changed[lut] or {}
        changed[lut][tonumber(row)] = goal
    end
    local out = {}
    for lut, rows in pairs(changed) do
        local original = target.luts[lut]
        local width, height = original.width, original.height
        local data = ffi.new('float[?]', width * height * 4)
        ffi.copy(data, original.values, width * height * 16)
        for r, goal in pairs(rows) do
            transfer.apply(data, width, r, goal.L, goal.a, goal.b, goal.cal)
            yield()
        end
        out[lut] = {width = width, height = height, data = data}
    end
    return out
end

-- A kit analysis's measured appearance for the matcher: {kit = its entry (or nil), row} (matcher v12), or nil
-- without the appearance table. The kit id is a number (game memory) or its 8 hex digits (tests' catalogue).
function Recolor.look_of(analysis, appearance)
    if not appearance then return nil end
    local id = analysis.kit.id
    if type(id) == 'number' then id = string.format('%08x', id) end
    return {kit = appearance.kit(id), row = appearance.row}
end

-- The texel color (sRGB) of a planned pattern: its desired color through the pattern's measured gain (matcher
-- v12: perceived = gain x texel color, linear), else the desired color itself.
function Recolor.pattern_texel(goal, colour)
    if not goal.gain then return colour.lab_to_srgb(goal.L, goal.a, goal.b) end
    local r, g, b = colour.lab_to_linear(goal.L, goal.a, goal.b)
    local to_srgb, gain = colour.linear_to_srgb, goal.gain
    return to_srgb(r / math.max(gain[1], 1e-4)), to_srgb(g / math.max(gain[2], 1e-4)),
        to_srgb(b / math.max(gain[3], 1e-4))
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
-- find(id) -> kit (src/kits.lua read_kit), read once per kit and kept. The first lookup reads every kit's id
-- (one read each); a miss reads them again once (kits loaded later).
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
        if kits[id] then return kits[id] end
        if not addresses or not addresses[id] then scan() end
        local address = addresses[id]
        if not address then error(string.format('kit %08x not in the catalogue', id), 0) end
        local kit, why = Kits.read_kit(read, address, buffer)
        if not kit then error(why, 0) end
        kits[id] = kit
        return kit
    end
    return self
end

-- The pipeline (created on the first job): the shared samples, color model, texture caches, analyses, plans
-- and the kit catalogue, kept for the session (well under 1 MB plus about 10 KB per kit), and the disk cache of
-- analyses and shared samples (src/cache.lua). The game-data reader and its buffers (index head, chunk tables,
-- decoding buffers: several MB) exist only while a job reads game files: open() before reading, close() when
-- the job ends. deps: {Files, Slim, Texture, Colour, Transfer, Kits, memory, game, Cache, cache_path, build
-- ({exe_sha256, game_sha256}), data_folder (tests only: a UTF-8 path)}.
local function pipeline(deps, yield)
    local Files, Slim, Texture, Colour, Kits = deps.Files, deps.Slim, deps.Texture, deps.Colour, deps.Kits
    local self = {analyses = {}, plans = {}, kits = catalogue(deps.memory, deps.game, Kits, yield), reads = 0,
                  bytes = 0, longest = 0, longest_size = 0, cached = {}, order = {}, dirty = false}
    local job = {texture = Texture, yield = yield} -- what the loaders read: reader, buffers, find

    -- The slim index's chunk count and size: they change with any update of the game data.
    local function data_signature()
        local folder, count = deps.data_folder, nil
        if not folder then folder, count = Files.game_data_folder() end
        local files = Files.new(folder, count)
        local handle = files.open('bundles.nxa')
        local head = ffi.new('uint8_t[32]')
        local ok, why = pcall(files.read, handle, 0, 32, head)
        files.close(handle)
        if not ok then error(why, 0) end
        local u32 = function(o) return head[o] + head[o + 1] * 256 + head[o + 2] * 65536 + head[o + 3] * 16777216 end
        return string.format('%d:%.0f', u32(8), u32(16) + u32(20) * HIGH)
    end

    -- The disk cache (deps.Cache, deps.cache_path, deps.build): analyses made in earlier sessions. A missing,
    -- older or damaged file leaves the cache empty; cache_status says which.
    if deps.Cache and deps.cache_path then
        self.header = deps.Cache.header(deps.build, data_signature())
        local text = deps.Cache.read(deps.cache_path)
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
        for k, v in pairs(self.analyses) do all[k] = v end
        for i, key in ipairs(self.order) do order[i] = key end
        self.dirty = false
        return deps.Cache.write(deps.cache_path, deps.Cache.encode(self.header, all, order, self.samples, yield))
    end

    function self.open()
        if job.slim then return end
        local folder, count = deps.data_folder, nil -- tests name the folder; the game's is found from its path
        if not folder then folder, count = Files.game_data_folder() end
        self.files = Files.new(folder, count, deps.memory.time)
        job.slim = Slim.open(self.files, '', yield)
        job.scratch, job.big_scratch = Slim.grower(65536), Slim.grower(Texture.COVERAGE_BLOCK)
        if not self.samples then
            self.samples = Kits.shared_samples(job.slim, Texture, job.scratch, yield)
            if not self.samples then error('shared customization archive not found', 0) end
            self.dirty = true -- the cache file keeps the samples
        end
        if not self.deps then self.deps = {yield = yield, textures = Kits.textures(job), colour = self.model()} end
        self.deps.slim, self.deps.scratch, self.deps.big_scratch = job.slim, job.scratch, job.big_scratch
    end

    -- The color model and the transfer over the shared samples (from the cache file, else the game files).
    function self.model()
        if not self.samples then self.open() end
        if not self.colour then
            local samples = self.samples
            self.colour = Colour.new(samples.detail, samples.detail_layers, samples.camo, samples.camo_layers)
            self.transfer = deps.Transfer.new(Colour, self.colour)
        end
        return self.colour, self.transfer
    end

    -- Closes the game files and drops the reader and its buffers (the garbage collector frees them).
    function self.close()
        if not job.slim then return end
        local files = self.files
        self.reads, self.bytes = self.reads + files.reads, self.bytes + files.bytes
        if files.longest > self.longest then self.longest, self.longest_size = files.longest, files.longest_size end
        pcall(job.slim.close)
        job.slim, job.scratch, job.big_scratch, job.find = nil, nil, nil, nil
        if self.deps then self.deps.slim, self.deps.scratch, self.deps.big_scratch, self.deps.find = nil, nil, nil, nil end
        self.files = nil
    end

    -- find searches the current kit's archive, then the shared one (set per analysis).
    function self.find_in(archive)
        local archives, slim = {archive, self.samples.archive}, job.slim
        local function find(name, kind)
            for _, candidate in ipairs(archives) do
                local record = slim.locate(candidate, name, kind)
                if record then return candidate, record end
            end
            return nil
        end
        self.deps.find, job.find = find, find
    end
    return self
end

-- The job: from a request {mode, keep_sets, helmet, armor, body} to {action = 'restore' | 'apply', key,
-- luts, patterns, first, last, target (analysis)}. Runs inside a coroutine; yield() pauses when the budget is
-- spent.
function Recolor.job(deps, state, request, yield)
    if request.mode == Recolor.OFF then return {action = 'restore', reason = 'off'} end
    state.pipeline = state.pipeline or pipeline(deps, yield)
    local p = state.pipeline
    state.stage = 'kit catalogue'
    local helmet, armor = p.kits.find(request.helmet), p.kits.find(request.armor)
    if request.keep_sets and helmet.name_upper == armor.name_upper then
        return {action = 'restore', reason = 'complete set'}
    end
    local function analysis(kit)
        local key = deps.Cache and deps.Cache.key(kit, request.body) or (kit.id .. ':' .. request.body)
        if not p.analyses[key] then
            if p.cached[key] then
                p.analyses[key] = p.cached[key]
            else
                state.stage = 'opening the game data'
                p.open()
                state.stage = string.format('analysing kit %08x', kit.id)
                p.find_in(kit.archive)
                p.analyses[key] = deps.Kits.analyse(kit, request.body, p.deps)
                p.dirty = true
            end
        end
        if deps.Cache then p.touch(key) end
        return p.analyses[key]
    end
    local h, a = analysis(helmet), analysis(armor)
    local target, source = h, a
    if request.mode == Recolor.ARMOR_FROM_HELMET then target, source = a, h end
    local key = table.concat({request.mode, request.helmet, request.armor, request.body}, ':')
    local made = p.plans[key]
    state.stage = 'plan'
    if not made then
        local Matcher, ARMOR = deps.Matcher, deps.Kits.ARMOR
        local t = Matcher.item(target.rows, target.kit.kit_type == ARMOR, Recolor.patterns_of(target),
                               Recolor.look_of(target, deps.Appearance))
        local s = Matcher.item(source.rows, source.kit.kit_type == ARMOR, Recolor.patterns_of(source),
                               Recolor.look_of(source, deps.Appearance))
        local plan, pattern_plan = Matcher.plan(t, s), Matcher.pattern_plan(t, s)
        state.stage = 'color transfer'
        local _, transfer = p.model()
        made = {luts = Recolor.build_luts(target, plan, transfer, yield),
                patterns = Recolor.build_patterns(target, pattern_plan, deps.Colour)}
        p.plans[key] = made
    end
    local slots = SLOTS[request.mode]
    return {action = 'apply', key = key, luts = made.luts, patterns = made.patterns, first = slots[1],
            last = slots[2], target = target}
end

-- The target pieces by unit position: {['type:slot'] = entry} for spawned, non-skin pieces with materials.
local function piece_index(target, body)
    local out = {}
    for _, entry in ipairs(target.pieces) do
        local piece = entry.piece
        local spawned = piece.body == body or piece.body == 3 or target.kit.kit_type == 'Helmet'
        local key = piece.type .. ':' .. piece.slot
        if spawned and not entry.skin and #entry.materials > 0 and not out[key] then out[key] = entry end
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
    local free = {} -- [width * 65536 + height] = {texture, ...}
    local self = {made = 0, refilled = 0, destroyed = 0}

    local function read(address, size, out) return memory.read_into(ffi.cast(POINTER, address), size, out) end
    local function list_for(width, height)
        local key = width * 65536 + height
        local list = free[key]
        if not list then
            list = {}
            free[key] = list
        end
        return list
    end
    local function make(spec)
        local texture, why = Engine.create_texture(native, spec.width, spec.height, spec.data, read, small)
        if texture then self.made = self.made + 1 end
        return texture, why
    end

    function self.take(spec)
        local list = list_for(spec.width, spec.height)
        local texture = list[#list]
        if texture then
            list[#list] = nil
            Engine.update_texture(native, texture, spec.data)
            self.refilled = self.refilled + 1
            return texture
        end
        local made, why = make(spec)
        if not made then return nil, why end
        for _ = 1, Recolor.POOL_SPARES do
            local spare = make(spec)
            if not spare then break end
            list[#list + 1] = spare
        end
        return made
    end

    function self.give(texture)
        local list = list_for(texture.width, texture.height)
        if #list >= Recolor.POOL_MAX_FREE then
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
    -- again): two reads per probe (one per runtime texture), alive() only on such a mismatch.
    function self.check()
        for i = 1, #probes do
            local b = probes[i]
            local bound = Engine.binding(read, b.material, b.slot, small, big)
            if bound == b.vanilla and native.alive(b.unit) ~= 0 then return false end
        end
        return true
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
        self.bindings, self.textures, self.key = {}, {}, nil
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

    -- Drops the bindings of dead units. The current plan's textures stay until the plan changes (a respawn
    -- binds the new units to them).
    function self.prune()
        local dead = false
        for _, b in ipairs(self.bindings) do
            if native.alive(b.unit) == 0 then dead = true break end
        end
        if not dead then return end
        local live = {}
        for _, b in ipairs(self.bindings) do
            if native.alive(b.unit) ~= 0 then live[#live + 1] = b end
        end
        self.bindings = live
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
    -- the plan changes a pattern); marks the meshes to commit. Returns how many bindings were made.
    local function bind_unit(result, u, vanilla, meshes)
        local count = 0
        for _, m in ipairs(Engine.unit_materials(native, u.unit)) do
            local lut = bind_slot(u, m, Engine.LUT_SLOT, result.luts, vanilla.luts)
            local pattern = vanilla.any_pattern and bind_slot(u, m, Engine.PATTERN_SLOT, result.patterns,
                                                              vanilla.patterns)
            if lut or pattern then meshes[m.mesh] = true end
            count = count + (lut and 1 or 0) + (pattern and 1 or 0)
        end
        return count
    end

    local function bind_units(result, identity, slot)
        local vanilla = {luts = vanilla_objects(result.luts), patterns = vanilla_objects(result.patterns)}
        vanilla.any_pattern = next(vanilla.patterns) ~= nil
        local pieces = piece_index(result.target, identity.body)
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
        self.key = result.key
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
    for _, fn in ipairs({Recolor.build_luts, Recolor.pattern_texel, Recolor.build_patterns, Recolor.look_of,
        Recolor.patterns_of, catalogue, pipeline,
        Recolor.job, piece_index, Recolor.pool, Recolor.controller}) do
        jit.off(fn, true)
    end
end

return Recolor
