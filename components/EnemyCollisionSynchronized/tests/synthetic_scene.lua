-- Synthetic native-layout scene for Enemy Collision Synchronized.
-- Real allocations in this test process stand in for game memory, so the mod's
-- own reader, caches, guards, budgets and native dispatch run unchanged while
-- every read is attributable to the structure it touched. Nothing here opens a
-- game process, and identical configurations produce identical work.
local S = {}
local DEFAULTS = {
    profile = 'Bile Titan',       -- single profile, or use profiles for a mixed manager
    profiles = nil,               -- cyclic roster of profile names for one scene
    living = 0,                   -- occupied entity slots whose unit is still alive
    ragdolls = 0,                 -- dead ragdoll-manager entities
    corpses = 0,                  -- corpse-manager entities
    motion = 'static',            -- 'static' frames a settled unit, 'dynamic' keeps it moving
    dynamic_mains = false,        -- move only the profiles' declared dynamic main bodies
    author_disabled = false,      -- apply the profile's authored disabled corpse bodies
    stopped = 0,                  -- leading dead ragdolls the engine already stopped
    recycled = 0,                 -- leading inspected units whose handle is stale
    expired_pool = false,         -- actor pool generation mask no longer matches
    -- Seconds added to the work clock per read. This assumption comes from
    -- recorder snapshot time / read count, which includes Python processing;
    -- it is not a measurement of ReadProcessMemory latency. Pass 0 to disable
    -- the time budget when comparing structural work at equal inspection counts.
    read_cost = 0.0000158,
    region_cost = nil,            -- extra seconds for reads inside one region
    hostile = nil,                -- {mode='nil'|'short', region=name, after=count}
}

local function catalog(M)
    local by_name = {}
    for key, value in pairs(M.profiles) do
        local aux = {}
        for name, node in pairs(value.actors) do
            if not value.main_names[name] then aux[#aux+1] = {name, node} end
        end
        -- Deterministic auxiliary order keeps actor rows reproducible.
        table.sort(aux, function(a, b) return a[1] < b[1] end)
        by_name[value.name] = {key=key, profile=value, aux=aux, actors=value.bodies+#aux}
    end
    return by_name
end
S.catalog = catalog

function S.names(M)
    local names = {}
    for name in pairs(catalog(M)) do names[#names+1] = name end
    table.sort(names)
    return names
end

function S.build(M, api, config)
    local ffi, bit = require('ffi'), require('bit')
    local cfg = {}
    for key, value in pairs(DEFAULTS) do cfg[key] = value end
    for key, value in pairs(config or {}) do cfg[key] = value end
    local by_name = catalog(M)
    local roster = {}
    for _, name in ipairs(cfg.profiles or {cfg.profile}) do
        local entry = assert(by_name[name], 'Unknown profile '..tostring(name))
        assert(entry.actors < 128, 'Actor list exceeds the 7-bit length field: '..name)
        roster[#roster+1] = entry
    end

    local owners, regions = {}, {}
    -- One arena keeps every structure at a fixed relative offset. The mod batches
    -- guard reads by address adjacency, so a real allocator's placement would
    -- otherwise change the measured read counts between two identical scenes.
    -- Every structure still gets its own named region, so a read is attributed to
    -- the exact game structure it touched instead of to a shared blob.
    -- The two module images dominate: the mod reads them at fixed offsets, so
    -- they cannot be shrunk. The remainder covers one large scene.
    local ARENA = 0x7400000 -- Includes the larger build-25327279 game image.
    local arena = ffi.new('uint8_t[?]', ARENA)
    owners[1] = arena
    local cursor = 0
    local function alloc(size, name)
        local span = math.max(size, 8)
        cursor = cursor+((-cursor)%8)
        assert(cursor+span<=ARENA,'Synthetic arena exhausted; trim the scenario or grow ARENA')
        local base = arena+cursor
        local from = tonumber(ffi.cast('uintptr_t', base))
        regions[#regions+1] = {name=name, from=from, to=from+span}
        cursor = cursor+span
        return base
    end
    -- A few structures live inside the module image itself rather than behind a
    -- pointer, so they are named in place instead of being allocated.
    local function region(name, at, size)
        local from = tonumber(ffi.cast('uintptr_t', at))
        -- Carve embedded headers out of their enclosing image. Binary search
        -- requires disjoint intervals, otherwise it can return the image name.
        for i, existing in ipairs(regions) do
            if from>=existing.from and from+size<=existing.to then
                table.remove(regions,i)
                if from>existing.from then
                    regions[#regions+1]={name=existing.name,from=existing.from,to=from}
                end
                if from+size<existing.to then
                    regions[#regions+1]={name=existing.name,from=from+size,to=existing.to}
                end
                break
            end
        end
        regions[#regions+1] = {name=name, from=from, to=from+size}
    end
    local function u(at, value) ffi.cast('uint32_t *', at)[0] = value end
    local function byte(at, value) ffi.cast('uint8_t *', at)[0] = value end
    local function p(at, value) ffi.cast('uint8_t **', at)[0] = value end
    local template = ffi.new('float[16]')
    local function matrix(at, x)
        ffi.copy(template, ffi.new('float[16]', {1,0,0,0, 0,1,0,0, 0,0,1,0, x or 0,0,0,1}), 64)
        ffi.copy(at, template, 64)
    end

    local game, exe = alloc(0x3330000,'game_image'), alloc(0x2800000,'exe_image')
    local mode = alloc(0x44,'mission_mode')
    u(mode+8,1); u(mode+0x40,2); p(game+0x33266a0,mode)

    local total = cfg.living+cfg.ragdolls+cfg.corpses
    local span = math.max(total,1)
    local registry = alloc(0xa8,'registry')
    local generations, slots = alloc(span,'generations'), alloc(span*8,'slots')
    p(exe+0x1a100f0,registry)
    p(registry+0xa0,generations); p(registry+0x88,slots); u(registry+0x98,span)
    ffi.fill(generations,span,1)
    local actortables = alloc(span*24,'actortables')
    p(exe+0x27c5b40,actortables)

    -- Describe every entity first so the shared actor pool can be sized exactly.
    local descriptors, rows_needed = {}, 0
    for _, corpse in ipairs({false,true}) do
        local count = corpse and cfg.corpses or (cfg.living+cfg.ragdolls)
        for index=0,count-1 do
            local slot = corpse and (cfg.living+cfg.ragdolls+index) or index
            local entry = roster[1+(slot%#roster)]
            -- A living unit still occupies a real entity record and pointer slot.
            -- The mod has to read both before the lifecycle check can reject it,
            -- so a scene that left them empty would price a crowd at nothing.
            local inspected = corpse or index>=cfg.living
            descriptors[#descriptors+1] = {corpse=corpse, index=index, slot=slot,
                unit=0x400000+slot, entry=entry, inspected=inspected}
            if inspected then rows_needed = rows_needed + entry.actors end
        end
    end
    local rows = math.max(rows_needed+1,1)
    local actor_rows, body_rows = alloc(rows*40,'actor_rows'), alloc(rows*160,'body_rows')
    -- The actor pool header is embedded at a fixed image offset, not pointed to.
    local pool = exe+0x2369b00+64*21
    region('actor_pool',pool,56)
    p(pool,actor_rows); u(pool+28,40); u(pool+36,rows); u(pool+40,0x0fffffff)
    u(pool+52,cfg.expired_pool and 0x40000000 or 0xc0000000)
    local world, vtable = alloc(64,'physics_world'), alloc(144,'physics_vtable')
    p(exe+0x27ba8a8+176*2,world)
    p(world,vtable); p(vtable+136,exe+0xd0cfa0); p(world+24,body_rows)

    local managers = {}
    for _, corpse in ipairs({false,true}) do
        local count = corpse and cfg.corpses or (cfg.living+cfg.ragdolls)
        local manager = alloc(88,corpse and 'corpse_manager' or 'ragdoll_manager')
        local pointers = alloc(math.max(count,1)*8,'entity_pointers')
        local runtime = alloc(math.max(count,1)*(corpse and 72 or 11192),
            corpse and 'corpse_runtime' or 'ragdoll_runtime')
        local sync = alloc(math.max(count,1)*(corpse and 56 or 432),
            corpse and 'corpse_sync' or 'ragdoll_sync')
        p(game+(corpse and 0x3326920 or 0x3326948),manager)
        if corpse then
            u(manager+16,count); u(manager+24,count); u(manager+28,count); p(manager+64,pointers)
        else
            u(manager+4,count); u(manager+12,count); u(manager+16,count); p(manager+56,pointers)
        end
        p(manager+72,runtime); p(manager+80,sync)
        managers[corpse and 'corpse' or 'ragdoll'] =
            {manager=manager,pointers=pointers,runtime=runtime,sync=sync,count=count}
    end

    local next_actor, meta, bodies, entities, unit_slots, unit_units, unit_corpse = 1, {}, {}, {}, {}, {}, {}
    for _, d in ipairs(descriptors) do
        local entry, store = d.entry, managers[d.corpse and 'corpse' or 'ragdoll']
        local profile = entry.profile
        local entity = alloc(24,'entity_record')
        ffi.copy(entity,entry.key,8); u(entity+8,d.slot+100); u(entity+12,d.unit)
        p(store.pointers+d.index*8,entity)
        if not d.corpse then
            local r = store.runtime+d.index*11192
            u(r+11160,profile.bodies)
            local stopped = d.index>=cfg.living and (d.index-cfg.living)<cfg.stopped
            byte(r+11172,stopped and 0 or 1)
            -- Living units keep the sync flag clear, which is the exact signal the
            -- mod uses to reject them before any skeleton or Havok read.
            if d.inspected then
                u(store.sync+d.index*432,profile.bodies); u(store.sync+d.index*432+184,profile.bodies)
            end
            meta[d.unit]={runtime=r,index=d.index,manager=store.manager}
        end
        if not d.inspected then
            assert(not d.corpse,'Living entities never belong to the corpse manager')
        else
        entities[d.unit]=entity; unit_slots[d.unit]=d.slot; unit_corpse[d.unit]=d.corpse
        unit_units[#unit_units+1]=d.unit
        local object, nodes = alloc(0x100,'unit_object'), alloc(profile.nodes*64,'node_matrices')
        p(slots+d.slot*8,object); u(object+8,d.unit); u(object+0x70,profile.nodes); p(object+0x88,nodes)
        for node=0,profile.nodes-1 do matrix(nodes+node*64) end
        local list = actortables+d.slot*24
        local handles = alloc(entry.actors*4,'actor_handles')
        u(list,d.unit); u(list+4,0x40000000+entry.actors); p(list+8,handles)
        local unit_bodies, aux = {}, 0
        for i=1,entry.actors do
            local id, is_main = 0x90000000+next_actor, i<=profile.bodies
            local ar, body = actor_rows+next_actor*40, body_rows+next_actor*160
            local name, node_hash
            if is_main then name, node_hash = profile.main[i], profile.main[i]
            else
                aux = aux+1
                name, node_hash = entry.aux[aux][1], entry.aux[aux][2]
            end
            u(handles+(i-1)*4,id)
            -- +20 is the Havok body index, which the mod re-validates against the
            -- body row's own identity before it trusts a transform.
            u(ar,id); u(ar+12,d.unit); u(ar+20,next_actor)
            u(ar+24,name); u(ar+28,i-1); u(ar+32,node_hash)
            local enabled = not (d.corpse and cfg.author_disabled and profile.disabled_main[name])
            u(ar+16,enabled and 1 or 0)
            local motion = 0
            if is_main then
                if cfg.motion=='dynamic' then motion = 1
                elseif cfg.dynamic_mains and profile.corpse_dynamic_main
                    and profile.corpse_dynamic_main[name] then motion = 1 end
            end
            matrix(body); u(body+64,motion)
            u(body+108,is_main and (d.corpse and 48 or 52) or 20)
            u(body+144,id); u(body+148,d.unit)
            unit_bodies[i]=body
            if not d.corpse and is_main then u(store.runtime+d.index*11192+(i-1)*712,id) end
            next_actor = next_actor+1
        end
        bodies[d.unit] = unit_bodies
        end
    end

    -- Recycle the leading inspected units so a stale handle can be staged.
    for i=1,math.min(cfg.recycled,#unit_units) do byte(generations+unit_slots[unit_units[i]],2) end

    local ordered = {}
    for _, region in ipairs(regions) do ordered[#ordered+1]=region end
    table.sort(ordered,function(a,b) return a.from<b.from end)
    local function classify(address)
        local low, high = 1, #ordered
        while low<=high do
            local middle = bit.rshift(low+high,1)
            local region = ordered[middle]
            if address<region.from then high=middle-1
            elseif address>=region.to then low=middle+1
            else return region.name end
        end
        return 'unknown'
    end

    local reads, bytes, work_clock, poll_clock = 0, 0, 0, 0
    local region_cost = cfg.region_cost or {}
    local hostile = cfg.hostile
    local hostile_served = 0
    local function base_read(address, size)
        reads = reads+1; bytes = bytes+size
        work_clock = work_clock+cfg.read_cost
        local class = classify(tonumber(ffi.cast('uintptr_t',address)))
        local extra = region_cost[class]
        if extra then work_clock = work_clock+extra end
        if hostile and (not hostile.region or hostile.region==class) then
            hostile_served = hostile_served+1
            if hostile_served>hostile.after then
                if hostile.mode=='nil' then return nil end
                if hostile.mode=='short' then return ffi.string(address,math.max(0,size-1)) end
            end
        end
        return ffi.string(address,size)
    end
    -- The production adapter's validation view: the same accounting and
    -- failures, but the scene's own bytes are compared in place (no string).
    local function base_view(address, size)
        reads = reads+1; bytes = bytes+size
        work_clock = work_clock+cfg.read_cost
        local class = classify(tonumber(ffi.cast('uintptr_t',address)))
        local extra = region_cost[class]
        if extra then work_clock = work_clock+extra end
        if hostile and (not hostile.region or hostile.region==class) then
            hostile_served = hostile_served+1
            if hostile_served>hostile.after then return nil end
        end
        return ffi.cast('const uint8_t *',address)
    end
    -- The scene owns the bytes; an api table is only a view onto them. Reusing
    -- one scene with a freshly attached api gives a second measurement window at
    -- identical addresses, which is how the harness separates real change from
    -- allocator placement.
    local function attach(target)
        target.read = base_read
        target.view = base_view
        target.view_read = base_read
        target.time = function() return poll_clock end
        target.clock = function() return work_clock end
        target.profiler = nil
        return target
    end
    attach(api)

    local commands = {pose=0,disable=0,stop_sync=0,request_completion=0,log={}}
    local function actor_index(id)
        local index=bit.band(id,0x0fffffff)
        assert(index>0 and index<rows,'Native command used an unknown actor')
        return index
    end
    local state = {native={
        pose=function(id,position,rotation)
            commands.pose=commands.pose+1;commands.log[#commands.log+1]={kind='pose',id=id}
            local x,y,z,w=unpack(rotation)
            local pose=ffi.cast('float *',body_rows+actor_index(id)*160)
            pose[0]=1-2*(y*y+z*z);pose[1]=2*(x*y+z*w);pose[2]=2*(x*z-y*w);pose[3]=0
            pose[4]=2*(x*y-z*w);pose[5]=1-2*(x*x+z*z);pose[6]=2*(y*z+x*w);pose[7]=0
            pose[8]=2*(x*z+y*w);pose[9]=2*(y*z-x*w);pose[10]=1-2*(x*x+y*y);pose[11]=0
            pose[12]=position[1];pose[13]=position[2];pose[14]=position[3];pose[15]=1
        end,
        disable=function(id)
            commands.disable=commands.disable+1;commands.log[#commands.log+1]={kind='disable',id=id}
            local flags=ffi.cast('uint32_t *',actor_rows+actor_index(id)*40+16)
            flags[0]=bit.band(flags[0],bit.bnot(1))
        end,
        stop_sync=function(manager,index)
            commands.stop_sync=commands.stop_sync+1
            commands.log[#commands.log+1]={kind='stop_sync',id=index}
            for _,row in pairs(meta) do
                if row.manager==manager and row.index==index then byte(row.runtime+11172,0) end
            end
        end,
        request_completion=function(id)
            commands.request_completion=commands.request_completion+1
            commands.log[#commands.log+1]={kind='request_completion',id=id}
        end}}

    local main_counts = {}
    for _, d in ipairs(descriptors) do
        if d.inspected then main_counts[d.unit] = d.entry.profile.bodies end
    end
    local function main_count(unit) return main_counts[unit] or 0 end
    -- Save only storage changed by commands and scenario controls. Restore it
    -- in place so independent windows retain identical guard-batching addresses.
    local reset_blocks={}
    for _,r in ipairs(regions) do
        if r.name=='actor_rows' or r.name=='body_rows' or r.name=='ragdoll_runtime'
            or r.name=='generations' or r.name=='mission_mode' then
            local address=ffi.cast('uint8_t *',r.from)
            reset_blocks[#reset_blocks+1]={address=address,bytes=ffi.string(address,r.to-r.from)}
        end
    end
    local controls = {
        tick=function(t) poll_clock=t end,
        reset=function()
            for _,block in ipairs(reset_blocks) do ffi.copy(block.address,block.bytes,#block.bytes) end
            commands.pose=0;commands.disable=0;commands.stop_sync=0;commands.request_completion=0;commands.log={}
            reads=0;bytes=0;work_clock=0;poll_clock=0;hostile_served=0;hostile=cfg.hostile
        end,
        u=u, matrix=function(at,x) matrix(at,x) end,
        units=unit_units, bodies=bodies, entities=entities, unit_count=#unit_units,
        is_corpse=function(unit) return unit_corpse[unit]==true end,
        recycle=function(unit) byte(generations+unit_slots[unit],2) end,
        accept_reads=function() hostile=nil end,
        leave_mission=function() u(mode+8,0) end,
        -- Auxiliary actors are the repair targets; moving only their bodies while
        -- the skeleton keeps the authored pose is exactly how a repair becomes due.
        displace_aux=function(unit,offset)
            local list = assert(bodies[unit])
            for i=main_count(unit)+1,#list do matrix(list[i],offset) end
        end,
        move=function(unit,offset)
            local list = assert(bodies[unit])
            for i=1,main_count(unit) do matrix(list[i],offset) end
        end,
    }

    return {api=api, game=game, exe=exe, state=state, controls=controls, regions=regions,
        commands=commands, owners=owners, classify=classify, attach=attach,
        reads=function() return reads end, bytes=function() return bytes end}
end

return S
