-- The Windows adapter. Reads, protection checks, writes, modules, their
-- SHA-256, the build check and the clock come from Bingus Shared Runtime v1:
-- memory is bingus_memory.lua's api extended by bingus_write.lua (private FFI
-- names; module hashes are read once per session for every mod). The write
-- into a range verified earlier in the same check, the terrain query and the
-- native sentry calls stay here. runtime (bingus_runtime.lua) is the core the
-- loader takes its guard from.
return function(runtime, memory)
    local ffi, bit = require('ffi'), require('bit')
    local kernel = memory.windows.kernel32
    local write_memory = assert(kernel.WriteProcessMemory, 'The memory api needs bingus_write.lua')
    -- Private names, declared once per game: ffi.cdef keeps the first
    -- declaration of a name for the whole game, so plain names could bind to
    -- another mod's. The game functions api.bind calls get named
    -- function-pointer types: each parse of a function-pointer type string
    -- adds C types (35 per bind) to the table every mod shares, which is never
    -- freed; a typedef name adds none, and neither does a declaration skipped
    -- here.
    if not pcall(ffi.typeof, 'sentry_aim_raycast_fn') then
        ffi.cdef [[
            typedef void (*sentry_aim_retention_fn)(void *, uint32_t, uint32_t, uint8_t);
            typedef void (*sentry_aim_speed_fn)(void *, float);
            typedef void (*sentry_aim_fire_mode_fn)(void *, uint32_t, uint32_t);
            typedef uint32_t (*sentry_aim_world_id_fn)(const void *);
            typedef uint32_t (*sentry_aim_raycast_fn)(uint32_t, const void *, const void *, float, uint32_t,
                uint32_t, uint32_t, uint32_t, uint32_t, void *, uint32_t);
        ]]
    end
    -- time: seconds as a Lua number from the performance counter, read without
    -- allocating (the 64-bit tick count this adapter read before was boxed,
    -- 16 bytes per call in interpreted code). Still one call per check once a
    -- sentry has been seen (pinned in tests/test_snapshot.lua).
    local api = {read = memory.read, read_into = memory.read_into, pointer = memory.pointer,
        address = memory.address, distance = memory.distance, writable_data = memory.writable_data, module = memory.module,
        module_hash = memory.module_hash, verify_build = memory.verify_build, time = memory.time}

    -- checked: the caller verified [address, address + #bytes) with
    -- writable_data earlier in the same check, so the write does not repeat
    -- that query (about 0.29 ms in game). Otherwise memory.write checks its
    -- range. The runtime's write always checks, so this write without a check
    -- stays here, through the WriteProcessMemory bingus_write.lua bound.
    local process, done = kernel.GetCurrentProcess(), ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    function api.write(address, bytes, checked)
        if not checked then return memory.write(address, bytes) end
        return write_memory(process, address, bytes, #bytes, done) ~= 0 and done32[0] == #bytes
    end
    -- The ray from origin to target: its start, unit direction and length, or
    -- nil when the points lie within 5 cm of each other.
    -- Reused ray buffers: a query allocates no buffer (one query at a time; the
    -- game runs this Lua on one thread).
    local from,to,dir=ffi.new('float[3]'),ffi.new('float[3]'),ffi.new('float[3]')
    local outputs={}
    local function terrain_ray(origin,target)
        assert(#origin==12 and #target==12,'Invalid terrain ray points')
        ffi.copy(from,origin,12);ffi.copy(to,target,12)
        local length=0
        for i=0,2 do
            local delta=tonumber(to[i]-from[i])
            assert(delta==delta and math.abs(delta)<100000,'Invalid terrain ray')
            dir[i]=delta;length=length+delta*delta
        end
        length=math.sqrt(length)
        if length<0.05 then return nil end
        assert(length<2000,'Terrain ray outside sentry range')
        for i=0,2 do dir[i]=dir[i]/length end
        return from,dir,length
    end
    -- Do not ignore the entire unit or stop at its first surface: solid
    -- terrain can sit behind a fence, including within the same unit.
    local function behind_cover(query,classify)
        local capacity=32
        local out,count=query(2,capacity)
        local nearest,cover
        for i=0,math.min(count,capacity)-1 do
            local solid,hit=classify(out,i)
            if solid and (not nearest or hit.distance<nearest.distance) then nearest=hit end
            if hit.reason=='destructible_cover' then cover=cover or hit end
        end
        if nearest then return true,nearest end
        -- A truncated result cannot establish obstruction. Leave that case to
        -- native ballistics instead of latching an unproven permanent pause.
        if count>capacity then return false,{reason='cover_query_limit',hits=count} end
        return false,cover or {reason='clear'}
    end
    -- Private-buffer adapter, also exercised with a synthetic terrain query.
    function api.cast_terrain(raycast,id,unit,origin,target,target_unit,actor_filter)
        local from,dir,length=terrain_ray(origin,target)
        if not from then return false end
        assert(id>=0 and id<4,'Invalid physics world')
        -- Match the native static-obstacle preset: closest collection, actor
        -- class 3, damage filter and flags 0x80000009. The native filter admits
        -- only bodies with the static bit. Character/ragdoll volumes, including
        -- initial overlaps around the muzzle, must not act as a firing veto.
        local function query(collection,capacity)
            local out=outputs[capacity]
            if not out then out=ffi.new('uint32_t[?]',11*capacity);outputs[capacity]=out end
            -- Nothing of an earlier query may read as a hit of this one.
            ffi.fill(out,44*capacity)
            local count=tonumber(raycast(id,from,dir,length,collection,3,0x393d9518,0x80000009,unit,out,capacity))
            assert(count and count>=0 and count==math.floor(count),'Invalid terrain hit count')
            return out,count
        end
        local function classify(out,index)
            local hit=out+11*index
            local distance=tonumber(ffi.cast('float *',hit)[6])
            assert(distance==distance and distance>=0 and distance<=length+0.05,'Invalid terrain hit')
            local hit_unit,actor=tonumber(hit[7]),tonumber(hit[8])
            local detail={hit_unit=hit_unit,hit_actor=actor,target_unit=target_unit,distance=distance,length=length}
            if target_unit and hit_unit==target_unit then detail.reason='target_surface';return false,detail end
            -- A surface endpoint is legal; only geometry before it can veto.
            if distance>=length-0.05 then detail.reason='endpoint';return false,detail end
            detail.filter=actor_filter and actor_filter(actor,hit_unit) or nil
            if detail.filter==0x04a8fbf9 then
                -- Native destructible cover includes fences. A collision here
                -- does not prove that the weapon cannot penetrate/destroy it.
                detail.reason='destructible_cover';return false,detail
            end
            detail.reason='static_obstruction';return true,detail
        end
        local out,count=query(1,1)
        if count==0 then return false,{reason='clear'} end
        local blocked,detail=classify(out,0)
        if detail.reason~='destructible_cover' then return blocked,detail end
        return behind_cover(query,classify)
    end
    -- The native actor/body mapping. Never dereference an unchecked actor handle
    -- or infer cover type from a recycled body index.
    -- The uint32 at byte offset o of b, or nil without b.
    local function word_at(b,o)
        if not b then return nil end
        local v=ffi.new('uint32_t[1]');ffi.copy(v,b:sub(o+1,o+4),4);return tonumber(v[0])
    end
    local function read_pointer(a)return api.pointer(api.read(a,8))end
    -- The actor's pool header, entry and collision record, or nil unless the
    -- handle resolves to this unit.
    local function actor_entry(exe,actor,unit)
        local world_index=math.floor(actor/0x40000000)
        local pool=exe+0x2369b00+64*(math.floor(actor/0x10000000)%4+10*world_index)
        local h=api.read(pool,56);if not h then return nil end
        local layout=word_at(h,28);local stride=layout%65536
        local identity=math.floor(layout/65536)%256;local offset=math.floor(layout/0x1000000)
        local index=bit.band(actor,word_at(h,40));local base=api.pointer(h)
        if not base or index<0 or index>=word_at(h,36) or bit.band(actor,word_at(h,52))==0
            or stride<40 or stride>512 or identity+4>stride or offset+40>stride then return nil end
        local entry=base+index*stride;local key=api.read(entry+identity,4)
        if word_at(key,0)~=actor then return nil end
        local record=api.read(entry+offset,40)
        if not record or word_at(record,12)~=unit then return nil end
        return {world_index=world_index,pool=pool,h=h,entry=entry,identity=identity,offset=offset,key=key,
            record=record}
    end
    -- The actor's physics body, checked against the actor and the unit.
    local function actor_body(exe,e,actor,unit)
        local world_slot=exe+0x27ba8a8+176*e.world_index;local world=read_pointer(world_slot)
        if not world then return false end
        local bodies=read_pointer(world+24);local body_index=bit.band(word_at(e.record,20),0xffffff)
        if not bodies or body_index>=262144 then return false end
        local address=bodies+160*body_index;local body=api.read(address,160)
        if not body or word_at(body,144)~=actor or word_at(body,148)~=unit then return false end
        e.world_slot,e.world,e.bodies,e.address,e.body=world_slot,world,bodies,address,body
        return true
    end
    -- The body's collision filter: true and its name word, or nil without a
    -- valid property table.
    local function filter_name(exe,e)
        local properties=read_pointer(exe+0x27c5e48);if not properties then return nil end
        local count=word_at(api.read(properties+248,4),0);local names=read_pointer(properties+256)
        local filter=bit.band(word_at(e.body,108),127)
        if not count or count>128 or filter>=count or not names then return nil end
        e.properties,e.count,e.names,e.filter=properties,count,names,filter
        return true,api.read(names+4*filter,4)
    end
    -- Every link read again: an actor, body or table that changed meanwhile
    -- gives no filter.
    local function unchanged(exe,e,name)
        return api.read(e.pool,56)==e.h and api.read(e.entry+e.identity,4)==e.key
            and api.read(e.entry+e.offset,40)==e.record and read_pointer(e.world_slot)==e.world
            and read_pointer(e.world+24)==e.bodies and api.read(e.address,160)==e.body
            and read_pointer(exe+0x27c5e48)==e.properties and read_pointer(e.properties+256)==e.names
            and word_at(api.read(e.properties+248,4),0)==e.count and api.read(e.names+4*e.filter,4)==name
    end
    function api.actor_filter(exe,actor,unit)
        local e=actor_entry(exe,actor,unit)
        if not e or not actor_body(exe,e,actor,unit) then return nil end
        local named,name=filter_name(exe,e)
        if not named or not unchanged(exe,e,name) then return nil end
        return word_at(name,0)
    end
    -- Once per session: aim_data keeps the bound natives (across a pause too).
    function api.bind(game,exe)
        -- Signatures and entity/record identity are checked before each call.
        local flag = ffi.cast('sentry_aim_retention_fn',game+0x6bf390)
        local horizontal = ffi.cast('sentry_aim_speed_fn',game+0x11cba20)
        local vertical = ffi.cast('sentry_aim_speed_fn',game+0x11cb930)
        local mode = ffi.cast('sentry_aim_fire_mode_fn',game+0x755f90)
        local world_id = ffi.cast('sentry_aim_world_id_fn',exe+0x79f860)
        local raycast = ffi.cast('sentry_aim_raycast_fn',exe+0x7f4590)
        local function ptr(address)
            return assert(api.pointer(api.read(address,8)),'Pose pointer unavailable')
        end
        -- Reused buffers: a word or the job table is read without allocating.
        local word,jobs=ffi.new('uint32_t[1]'),ffi.new('uint32_t[72]')
        local function uint(address)
            assert(api.read_into(address,4,word),'Pose metadata unavailable')
            return tonumber(word[0])
        end
        -- The path from the unit table to a unit's object, checked in full; the
        -- object's pose code is checked here, once per path.
        local poses,pose_count={},0
        local function locate_pose(units,unit)
            local index=unit%0x400000
            assert(index<uint(units+0x98),'Unit index unavailable')
            local generations=ptr(units+0xa0)
            local generation=string.char(math.floor(unit/0x400000)%256)
            assert(api.read(generations+index,1)==generation,'Unit generation changed')
            local slot=ptr(units+0x88)+8*index;local object=ptr(slot)
            assert(uint(object+8)==unit,'Fire node unavailable')
            assert(api.read(ptr(ptr(object)+0xe8),5)=='\x48\x8d\x41\x60\xc3','Unsupported pose layout')
            return {units=units,index=index,generations=generations,generation=generation,slot=slot,
                object=object,nodes=uint(object+0x70)}
        end
        return {
            retention=function(id,enabled) flag(nil,id,2,enabled and 1 or 0) end,
            horizontal=function(entity,speed) horizontal(entity,speed) end,
            vertical=function(entity,speed) vertical(entity,speed) end,
            fire_mode=function(manager,id,value) mode(manager,id,value) end,
            terrain_path=function(unit,origin,target,target_unit)
                -- The native ray workers use this scheduler. Query only after
                -- consumption, using private inputs/output; never enqueue work.
                local scheduler=api.pointer(api.read(game+0x347d7e0,8))
                local world=api.pointer(api.read(game+0x346bfa0,8))
                if not scheduler or not world or uint(scheduler)~=0 then return nil end
                if not api.read_into(scheduler+0x40008,288,jobs) then return nil end
                for i=0,23 do if jobs[3*i+2]~=1 then return nil end end
                return api.cast_terrain(raycast,tonumber(world_id(world)),unit,origin,target,target_unit,
                    function(actor,owner)return api.actor_filter(exe,actor,owner)end)
            end,
            pose=function(unit,node)
                -- Read the same matrix selected by UnitApi.world_pose, without
                -- invoking an engine virtual function on a possibly stale unit.
                -- The path to the unit's object is kept per unit while the unit
                -- table, the unit's generation, its slot and the object's unit
                -- id stay the same.
                local units=ptr(exe+0x1a100f0)
                local p=poses[unit]
                if not (p and p.units==units and api.read(p.generations+p.index,1)==p.generation
                    and ptr(p.slot)==p.object and uint(p.object+8)==unit) then
                    p=locate_pose(units,unit);poses[unit]=p;pose_count=pose_count+1
                    -- Bounded: units are recycled, so a long session forgets old paths.
                    if pose_count>64 then poses={[unit]=p};pose_count=1 end
                end
                assert(node<p.nodes,'Fire node unavailable')
                local matrix=api.read(ptr(p.object+0x88)+64*node,64)
                assert(api.read(p.generations+p.index,1)==p.generation,'Pose identity changed')
                return matrix
            end,
        }
    end
    return api
end
