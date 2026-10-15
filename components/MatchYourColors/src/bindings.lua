-- Match Your Colors: the bindings controller (Recolor.controller; split from src/recolor.lua in v1.5).
--
-- A plan (a job's result, src/recolor.lua) is applied in one frame: runtime textures (RenderBufferApi), bound to
-- the target units' materials whose LUT (or pattern) is one the plan changes, meshes committed. Bindings are
-- tracked {unit, mesh, material, slot, vanilla texture object} so they can be put back.
--
-- Texture lifetime: a plan's textures live until the plan changes (another kit, direction or Off) or the
-- addon pauses or stops: then the vanilla textures go back on every live tracked material, and the textures
-- go back to the pool RETIRE_FRAMES frames later (the render thread may still draw a frame that used them). The
-- pool refills a free texture for the next plan instead of making a new one: making a texture waits for the
-- render thread (about one frame, src/engine.lua), refilling one does not.
local ffi = require('ffi')

local Bindings = {}
-- src/recolor.lua, set by Bindings.attach: its PENDING_EVERY, PENDING_FRAMES, RETIRE_FRAMES and ATTACHMENT
local Recolor

-- The target pieces by unit position: {['type:slot'] = entry} for spawned pieces with materials, over every target
-- analysis (a paint scheme has two: helmet and armor). Pieces with skin tones are bound too: their LUT materials are
-- clothing (until 2026-10-09 they were left out, and a shirt such as the PH-9 Predator's kept its colors).
local function piece_index(targets, body)
    local out = {}
    for _, target in ipairs(targets) do
        for _, entry in ipairs(target.pieces) do
            local piece = entry.piece
            local spawned = piece.body == body or piece.body == 3 or target.kit.kit_type == 'Helmet'
            local key = piece.type .. ':' .. piece.slot
            if spawned and #entry.materials > 0 and not out[key] then out[key] = entry end
        end
    end
    return out
end

-- The bindings controller. deps: {Engine, Avatar, memory, native, pool (Engine.pool), units (optional: units(identity)
-- -> {{unit, any = true}, ...}, the weapons' units, src/weapons.lua; default the avatar's arrays by piece slot)}.
function Bindings.controller(deps)
    local Engine, Avatar, memory, native, pool = deps.Engine, deps.Avatar, deps.memory, deps.native, deps.pool
    local units_of = deps.units
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

    -- Puts the vanilla texture back on each of `bindings` not taken over by a new plan (bind_slot) whose material, on a
    -- live unit, still holds its texture.
    local function put_back(bindings)
        local meshes = {}
        for _, b in ipairs(bindings) do
            if not b.taken and native.alive(b.unit) ~= 0
                and Engine.binding(read, b.material, b.slot, small, big) == b.texture then
                Engine.bind(native, b.material, b.slot, b.vanilla)
                meshes[b.mesh] = true
                self.restored = self.restored + 1
            end
        end
        commit(meshes)
    end

    -- Forgets all bindings and retires every current texture; returns the bindings it forgot.
    local function retire(frame)
        local bindings = self.bindings
        for _, texture in pairs(self.textures) do
            texture.retired_at = frame
            self.retired[#self.retired + 1] = texture
        end
        self.bindings, self.textures, self.key, self.result = {}, {}, nil, nil
        rebuild_probes()
        return bindings
    end

    -- Puts the vanilla texture back on every tracked material of a live unit; forgets all bindings and
    -- retires every current texture.
    function self.restore(frame)
        put_back(retire(frame))
    end

    -- The bindings of the plan before, while a new plan's apply binds (self.apply): {[material] = {[slot] = binding}}.
    local before = nil
    local function index_of(bindings)
        local out = {}
        for _, b in ipairs(bindings) do
            local slots = out[b.material]
            if not slots then
                slots = {}
                out[b.material] = slots
            end
            slots[b.slot] = b
        end
        return out
    end

    -- Gives retired textures back to the pool RETIRE_FRAMES frames after they were retired. Returns how many remain.
    function self.collect(frame)
        local keep = {}
        for _, texture in ipairs(self.retired) do
            if frame - texture.retired_at >= Recolor.RETIRE_FRAMES then
                if not texture.direct then pool.give(texture) end -- a game texture (texture_for) is not the pool's
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
    -- A direct spec ({direct = name}: a weapon scheme's decal sheet, src/recolor.lua weapon_luts) is the game's own
    -- texture, bound as it is (nil while the game has not loaded it); never the pool's, never given back to it.
    local function texture_for(specs, name)
        local texture = self.textures[name]
        if texture then return texture end
        if specs[name].direct then
            local object = Engine.texture_object(native, specs[name].direct)
            if not object then return nil end
            self.textures[name] = {object = object, direct = true}
            return self.textures[name]
        end
        local made, why = pool.take(specs[name])
        if not made then error('texture for ' .. name .. ': ' .. why, 0) end
        self.textures[name] = made
        return made
    end

    -- {vanilla texture object -> name} for the planned LUTs or patterns, and the same for the attachment LUTs of a
    -- weapons plan (names ending in Recolor.ATTACHMENT) or nil.
    local function vanilla_objects(specs)
        local out, attached = {}, nil
        local tail = #Recolor.ATTACHMENT
        for name in pairs(specs or {}) do
            local base = name:sub(-tail) == Recolor.ATTACHMENT and name:sub(1, -tail - 1) or nil
            local object = Engine.texture_object(native, base or name)
            if object and base then
                attached = attached or {}
                attached[object] = name
            elseif object then
                out[object] = name
            end
        end
        return out, attached
    end

    -- Binds the planned texture to slot `slot` of material m (held: its bindings, read into big by Engine.bindings)
    -- when its vanilla texture is one the plan changes; true when it bound. A slot holding the plan before's texture
    -- (before) counts as holding that binding's vanilla texture, and the binding is taken over: bound over at once,
    -- not put back first (v1.3 restored every binding of the plan before, two reads and a bind each, then read each
    -- slot again).
    -- Whether object is one of this controller's textures (bound now, or retired and not given back yet).
    local function owned(object)
        for _, texture in pairs(self.textures) do if texture.object == object then return true end end
        for _, texture in ipairs(self.retired) do if texture.object == object then return true end end
        return false
    end

    -- waiting: a slot that holds a texture neither the plan changes nor ours is added to it (the game may not have
    -- given the material its own texture yet: settle).
    local function bind_slot(u, m, held, slot, specs, vanilla, waiting)
        local bound = Engine.binding_in(big, held, slot)
        local slots = bound and before and before[m.material]
        local old = slots and slots[slot]
        if old and old.texture ~= bound then old = nil end
        local original = old and old.vanilla or bound
        local name = original and vanilla[original]
        if not name then
            if bound and waiting and not owned(bound) then
                waiting[#waiting + 1] = {unit = u.unit, mesh = m.mesh, material = m.material, slot = slot, specs = specs,
                                         vanilla = vanilla}
            end
            return false
        end
        local texture = texture_for(specs, name)
        if not texture then return false end -- a direct texture the game has not loaded
        Engine.bind(native, m.material, slot, texture.object)
        if old then old.taken = true end
        self.bindings[#self.bindings + 1] = {unit = u.unit, mesh = m.mesh, material = m.material, slot = slot,
                                             vanilla = original, texture = texture.object}
        return true
    end

    -- Binds unit u's material m in each of slots ({slot, specs, vanilla objects}) the plan changes, its bindings read
    -- once for all of them (v1.3 read them again for each slot); marks its mesh to commit. Returns how many it bound.
    local function bind_material(u, m, slots, meshes, waiting)
        local held = Engine.bindings(read, m.material, small, big)
        if not held then return 0 end
        local count = 0
        for _, s in ipairs(slots) do
            if bind_slot(u, m, held, s[1], s[2], s[3], waiting) then
                meshes[m.mesh], count = true, count + 1
            end
        end
        return count
    end

    -- Binds the planned textures to every target unit's materials whose LUT (or pattern) the plan changes. A
    -- unit already bound keeps its binding. Returns how many bindings were made now.
    -- Binds one unit's materials (vanilla: {luts, patterns} objects by name; the pattern slot is read only when
    -- the plan changes a pattern, the cape LUT slot only on the cape's unit (slot 1) when the plan changes its tint);
    -- marks the meshes to commit. Returns how many bindings were made.
    local function bind_unit(result, u, vanilla, meshes, waiting)
        local luts = u.attachment and vanilla.attached or vanilla.luts
        local slots = {{Engine.LUT_SLOT, result.luts, luts}}
        if vanilla.any_pattern then slots[#slots + 1] = {Engine.PATTERN_SLOT, result.patterns, vanilla.patterns} end
        -- a weapon's unit: a scheme's decal sheet (NIGHT's) over its own
        if u.any and vanilla.any_decal then slots[#slots + 1] = {Engine.DECAL_SLOT, result.luts, luts} end
        if u.slot == 1 then -- the cape's unit: its tint and its emblems' sheet
            if vanilla.any_tint then slots[#slots + 1] = {Engine.CAPE_LUT_SLOT, result.luts, vanilla.luts} end
            if vanilla.any_sheet then slots[#slots + 1] = {Engine.DECAL_SLOT, result.luts, vanilla.luts} end
        end
        if vanilla.any_albedo then slots[#slots + 1] = {Engine.ALBEDO_SLOT, result.luts, vanilla.luts} end
        local count, materials = 0, Engine.unit_materials(native, u.unit)
        for _, m in ipairs(materials) do count = count + bind_material(u, m, slots, meshes, waiting) end
        return count, #materials
    end

    -- Whether any planned texture is of a kind (field: 'cape', a cape LUT copy, Recolor.build_luts; 'sheet', a decal
    -- sheet copy, Recolor.sheet_spec).
    local function any_of(luts, field)
        for _, spec in pairs(luts) do
            if spec[field] then return true end
        end
        return false
    end

    -- The textures this apply can take, per size (planned LUTs and patterns whose vanilla texture is loaded, not held
    -- yet), reserved in the pool before any is taken (pool.reserve).
    local function reserve(result, vanilla)
        local demand = {}
        for _, kind in ipairs({'luts', 'patterns', 'attached'}) do
            local specs, names = result[kind == 'attached' and 'luts' or kind], vanilla[kind]
            if kind == 'attached' and names == vanilla.luts then names = {} end
            for _, name in pairs(names) do
                if not self.textures[name] and not specs[name].direct then
                    local spec = specs[name]
                    local size = Engine.pool_key(spec)
                    local d = demand[size] or {spec = spec, count = 0}
                    d.count, demand[size] = d.count + 1, d
                end
            end
        end
        for _, d in pairs(demand) do pool.reserve(d.spec, d.count) end
    end

    -- Binds the plan's target units (only: {[unit] = true}, else every one); returns how many bindings were made, the
    -- target units that had no materials ({[unit] = true}: dead, or not ready yet) or nil, and the slots left waiting
    -- (bind_slot) or nil.
    -- The plan's vanilla texture objects ({luts, patterns, attached} by object) and which slots it changes.
    local function vanilla_of(result)
        local luts, attached = vanilla_objects(result.luts)
        local vanilla = {luts = luts, patterns = vanilla_objects(result.patterns)}
        -- an attachment unit takes its own LUTs, else the weapon's (Recolor.ATTACHMENT)
        vanilla.attached = attached and setmetatable(attached, {__index = luts}) or luts
        vanilla.any_pattern = next(vanilla.patterns) ~= nil
        vanilla.any_tint, vanilla.any_sheet = any_of(result.luts, 'cape'), any_of(result.luts, 'sheet')
        vanilla.any_albedo = any_of(result.luts, 'albedo')
        vanilla.any_decal = any_of(result.luts, 'decal') -- a weapon scheme's decal sheet (texture_for)
        return vanilla
    end

    local function bind_units(result, identity, slot, only)
        local vanilla = vanilla_of(result)
        reserve(result, vanilla)
        local pieces = piece_index(result.targets or {result.target}, identity.body)
        local meshes, count, pending, waiting = {}, 0, nil, {}
        local list = units_of and units_of(identity) or Avatar.units(memory, identity, slot, result.first, result.last)
        for _, u in ipairs(list) do
            if (u.any or pieces[u.type .. ':' .. u.slot]) and (not only or only[u.unit]) then
                local bound, materials = bind_unit(result, u, vanilla, meshes, waiting)
                count = count + bound
                if materials == 0 then
                    pending = pending or {}
                    pending[u.unit] = true
                end
            end
        end
        commit(meshes)
        return count, pending, waiting[1] and waiting or nil
    end

    -- Applies a job result: a new plan binds its textures over the plan before's (bind_slot) and puts the vanilla
    -- textures back where it binds none, after; the same plan only binds units that are still vanilla (a respawn, a
    -- new preview).
    function self.apply(result, identity, slot, frame)
        if result.action == 'restore' then
            self.restore(frame)
            return 0
        end
        local replaced = self.key ~= result.key and retire(frame) or nil
        before = replaced and index_of(replaced)
        self.key, self.result = result.key, result
        local ok, count, pending, waiting = pcall(bind_units, result, identity, slot)
        before = nil
        if replaced then put_back(replaced) end -- also when binding failed: none of the plan before stays bound
        if not ok then error(count, 0) end
        self.pending = (pending or waiting) and {units = pending, slots = waiting, identity = identity, slot = slot,
                                                 since = frame} or nil
        self.prune()
        rebuild_probes()
        self.applied = self.applied + count
        return count
    end

    -- One waiting slot read again (settle): bound when it now holds a texture the plan changes. Returns whether it is
    -- done (bound, its unit gone, or one of ours bound there) and whether it bound.
    local function retry_slot(e, meshes)
        if native.alive(e.unit) == 0 then return true, false end
        local held = Engine.bindings(read, e.material, small, big)
        local bound = held and Engine.binding_in(big, held, e.slot)
        local name = bound and e.vanilla[bound]
        if not name then return bound ~= nil and owned(bound), false end
        local texture = texture_for(e.specs, name)
        Engine.bind(native, e.material, e.slot, texture.object)
        self.bindings[#self.bindings + 1] = {unit = e.unit, mesh = e.mesh, material = e.material, slot = e.slot,
                                             vanilla = bound, texture = texture.object}
        meshes[e.mesh] = true
        return true, true
    end

    -- The last apply's target units without materials and slots holding a texture neither the plan's nor ours
    -- (self.pending; live sessions 2026-10-14: in the Armory, an armor changed under the same cape gave the preview a
    -- new cape unit whose LUT slots held a placeholder until the game set the kit's LUT a few frames later; a plan
    -- applied before that, as a kept plan is within 2 frames, bound nothing there and nothing bound it later, so the
    -- cape kept its own colors) bound once they are ready: on every PENDING_EVERY-th frame for PENDING_FRAMES frames
    -- after the apply, those units and slots alone. A slot on a LUT the plan does not change waits to the end too.
    -- Returns how many bindings it made and 'done', 'pending' or 'expired' (units still without materials at the end).
    -- The pending units tried again (settle): bindings made, units still without materials, slots now waiting.
    local function retry_units(p)
        if not p.units then return 0, nil, nil end
        local ok, count, still, waiting = pcall(bind_units, self.result, p.identity, p.slot, p.units)
        if not ok then
            self.pending = nil
            error(count, 0)
        end
        return count, still, waiting
    end

    -- The waiting slots tried again (settle) after slots (the units' new ones): bindings made, slots still waiting.
    local function retry_slots(p, slots)
        local meshes, count = {}, 0
        for _, e in ipairs(p.slots or {}) do
            local done, bound = retry_slot(e, meshes)
            if bound then count = count + 1 end
            if not done then
                slots = slots or {}
                slots[#slots + 1] = e
            end
        end
        commit(meshes)
        return count, slots
    end

    function self.settle(frame)
        local p = self.pending
        local age = frame - p.since
        if age % Recolor.PENDING_EVERY ~= 0 then return 0, 'pending' end
        if age > Recolor.PENDING_FRAMES or not self.result then
            self.pending = nil
            return 0, p.units and 'expired' or 'done'
        end
        local count, units, slots = retry_units(p)
        local late
        late, slots = retry_slots(p, slots)
        count = count + late
        p.units, p.slots = units, slots
        if not units and not slots then self.pending = nil end
        if count > 0 then
            rebuild_probes()
            self.applied = self.applied + count
        end
        return count, self.pending and 'pending' or 'done'
    end
    return self
end

-- Recolor.controller (src/recolor.lua callers: src/addon.lua, src/loadout.lua, src/remote.lua).
function Bindings.attach(recolor)
    Recolor = recolor
    recolor.controller = Bindings.controller
end

-- Runs on applies, checks and events, never in a hot loop: interpreted, sub-functions included (no traces in the
-- LuaJIT code cache the game and every mod share).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({piece_index, Bindings.controller, Bindings.attach}) do
        jit.off(fn, true)
    end
end

return Bindings
