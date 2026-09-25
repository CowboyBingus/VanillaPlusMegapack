local ffi, bit = require('ffi'), require('bit')
local M = {}
local INVALID = 0xffffffff
-- Fields decode through one reused cell per type. The previous b:sub(o+1)
-- copied the whole rest of the buffer for every field read; out-of-range
-- offsets keep that original path, so every result is unchanged.
local decode_cells={}
local function value(bytes,offset,kind)
    local cell=decode_cells[kind]
    if not cell then cell=ffi.new(kind..'[1]');decode_cells[kind]=cell end
    local size=ffi.sizeof(cell)
    if offset>=0 and offset+size<=#bytes then ffi.copy(cell,ffi.cast('const uint8_t *',bytes)+offset,size)
    else ffi.copy(cell,bytes:sub(offset+1),size) end
    return tonumber(cell[0])
end
local function u32(b,o) return value(b,o,'uint32_t') end
local function u16(b,o) return value(b,o,'uint16_t') end
local function number(b,o) return value(b,o,'float') end
local function finite(n) return n == n and math.abs(n) < 100000 end
local function f32(n) return tonumber(ffi.new('float[1]',n)[0]) end
local function vector(b,o)
    local v = {number(b,o),number(b,o+4),number(b,o+8)}
    assert(finite(v[1]) and finite(v[2]) and finite(v[3]), 'Invalid vector')
    return v
end
local function normalize(v)
    local length = f32(math.sqrt(f32(f32(f32(v[1]^2)+f32(v[2]^2))+f32(v[3]^2))))
    if length < 0.0001 then return nil end
    return {f32(v[1]/length),f32(v[2]/length),f32(v[3]/length)}
end
local function pair(unit,actor)
    return ffi.string(ffi.new('uint32_t[2]',{unit,actor}),8)
end

-- Only guards independent of the eight-byte query fields belong to an epoch.
-- This allows restoration after manual input is released, but not after reuse.
function M.same_epoch(api,s)
    for _,g in ipairs(s.epoch) do
        if api.read(g.address,#g.bytes) ~= g.bytes then return false end
    end
    return true
end

function M.snapshot(api,game,exe,state,discovery)
    local s = {epoch={},guards={},hits={}}
    local function read(address,size,epoch)
        local bytes = assert(api.read(address,size),'Game data unavailable')
        assert(#bytes==size,'Short game read')
        local guard={address=address,bytes=bytes}
        s.guards[#s.guards+1]=guard
        if epoch then s.epoch[#s.epoch+1]=guard end
        return bytes
    end
    local function pointer(bytes,offset)
        return assert(api.pointer(bytes,offset),'Game pointer unavailable')
    end
    local function global(rva,epoch) return pointer(read(game+rva,8,epoch)) end
    local function lookup(header,key,limit)
        local capacity,empty,mult=u32(header,8),u32(header,12),u32(header,16)
        assert(capacity<=limit and capacity>0 and bit.band(capacity,capacity-1)==0,'Unsupported map')
        local data=pointer(header)
        -- Keep the low product exact even for a full uint32 key/multiplier.
        -- It does not depend on the probe index, so it is computed once.
        local low=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*ffi.new('uint64_t',mult)))
        for probe=0,math.min(capacity,128)-1 do
            local slot=bit.band(low+probe,capacity-1)
            local row=read(data+slot*8,8)
            if u32(row,0)==key then return u32(row,4) end
            if u32(row,0)==empty then return nil end
        end
        return nil
    end
    local mode=read(global(0x33266a0),0x44)
    if u32(mode,8)==0 or u32(mode,0x40)<1 or u32(mode,0x40)>7 then return nil,'waiting_for_mission' end
    local pm=global(0x3326468,true)
    local counts=read(pm+0x84,8)
    assert(u32(counts,0)<=4 and u32(counts,4)<=4,'Unsupported player count')
    if u32(counts,0)==0 or u32(counts,4)==0 then return nil,'waiting_for_local_player' end
    local player=read(pointer(read(pm+0xe8,8,true)),24,true)
    if bit.band(player:byte(21),1)==0 then return nil,'waiting_for_local_player' end
    local unit_ref=u32(read(pm+0x3a8,4,true),0)
    if unit_ref==0x7fff then return nil,'waiting_for_local_avatar' end
    local owner=global(0x346bf98,true)
    local ei=lookup(read(owner+0xf22ec8,20),unit_ref,1048576)
    if not ei or ei==INVALID then return nil,'waiting_for_local_avatar' end
    assert(ei<262144,'Unsupported entity index')
    local entity_address=owner+0xf32f18+ei*24
    local entity=read(entity_address,24,true)
    -- Resource 0x4d1c334d294dfa97, kept as bytes to avoid floating-point hashing.
    assert(entity:sub(1,8)=='\151\250\077\041\077\051\028\077','Unsupported avatar resource')
    if bit.band(entity:byte(21),1)==0 then return nil,'waiting_for_local_avatar' end
    local id=u32(entity,8)
    local manager=global(0x3326d20,true)
    local ai=lookup(read(manager+0xf8,20),id,64)
    if not ai or ai==INVALID then return nil,'waiting_for_local_avatar' end
    local n=u32(read(manager+0x6c,4),0)
    assert(n<=8 and ai<n,'Unsupported avatar index')
    assert(read(pointer(read(manager+0x110+ai*8,8,true)),24,true)==entity,'Avatar registry mismatch')
    s.controller=manager+0x53e1b8+ai*0x1238
    assert(u32(read(s.controller+0x2ac,4,true),0)==id,'Controller identity mismatch')
    local epoch=read(s.controller+4,44)
    s.stage=u32(epoch,0)
    if state then
        local key='stage_'..s.stage
        state[key]=(state[key] or 0)+1
    end
    if s.stage~=2 and s.stage~=3 then return nil,'waiting_for_vault_query' end
    -- The late retry temporarily returns stage 3 to stage 2. The query IDs,
    -- entity and records still define the epoch across that native call.
    read(s.controller+8,40,true)
    if s.stage==2 then read(s.controller+4,4,true) end
    s.input_address=manager+0x150+ai*0xa7aec+0x1b68+14*32
    s.manual_bytes=read(s.input_address,1)
    if s.manual_bytes:byte()==0 then return nil,'waiting_for_manual_vault' end
    s.manual=true
    local controller=read(s.controller,0x2b0)
    s.controller_bytes=controller
    s.flags_address=manager+ai*0x1238+0x53e880
    local flags=read(s.flags_address,24)
    if s.stage==3 then
        -- Match A88020/A88160 before re-entering the original local driver.
        local climbing=bit.band(u32(flags,12),0x200)~=0
        local excluded=bit.band(u32(flags,0),0x404000)~=0
            or bit.band(u32(flags,4),0x8000000)~=0
            or bit.band(u32(flags,8),0x20084000)~=0
            or bit.band(u32(flags,12),0x5181c)~=0
            or bit.band(u32(flags,16),9)~=0
        -- +532 is pending climb readiness. +533 only reports an automatic
        -- step; A8A710 can retain it across later failed detections. A88160
        -- does not use that report as an eligibility veto. Never clear it.
        s.prior_step_report=controller:byte(0x216)~=0
        if climbing or excluded or bit.band(u32(flags,0),2)==0
            or controller:byte(0x215)~=0 then
            return nil,'native_vault_state_retained'
        end
    end
    local scheduler=pointer(read(manager+0x28,8,true))
    local jobs=read(scheduler+0x40000,100,true)
    local total=u32(jobs,0)
    if s.stage==3 then
        -- Lua runs after consumption. Require an idle scheduler before using
        -- retained descriptors or rebuilding private discovery queries.
        if total~=0 then return nil,'waiting_for_idle_query_scheduler' end
        for job=0,7 do
            if u32(jobs,12+job*12)~=1 then return nil,'waiting_for_query_workers' end
        end
        s.world=global(0x346bfa0,true)
    else assert(total>0 and total<=2048,'Unsupported query count') end
    local seen,records={},{}
    for slot=0,9 do
        local query=u32(epoch,4+slot*4)
        assert(query>0 and query<=(s.stage==3 and 2048 or total) and not seen[query],'Unsupported query ID')
        seen[query]=true
        local completed=false
        for job=0,7 do
            local start,finish,done=u32(jobs,4+job*12),u32(jobs,8+job*12),u32(jobs,12+job*12)
            if query-1>=start and query-1<finish and done==1 then completed=true end
        end
        if s.stage==2 and not completed then return nil,'waiting_for_query_workers' end
        local address=scheduler+(query-1)*128
        -- Ownership must be established for the whole batch before any shared
        -- descriptor becomes a guard. Reused records are never our epoch.
        local record=assert(api.read(address,128),'Game data unavailable')
        assert(#record==128,'Short game read')
        local hit_address=s.controller+0x30+44*slot
        local output=api.pointer(record)
        if not output or api.distance(output,hit_address)~=0 then
            if s.stage~=3 then error('Query output is not local controller data') end
            if discovery~=true then return nil,'retained_query_reused' end
            s.rebuild_queries=true
        end
        records[#records+1]={address=address,bytes=record,hit_address=hit_address}
    end
    for i,row in ipairs(records) do
        local record,count=row.bytes
        if s.rebuild_queries then
            -- A9BE10 / 175BA70's fixed query metadata. Geometry is populated
            -- only after a successful fresh native approach in M.refresh.
            local template=ffi.new('uint8_t[128]')
            ffi.cast('uintptr_t *',template)[0]=ffi.cast('uintptr_t',row.hit_address)
            ffi.cast('uint32_t *',template+0x68)[0]=0x05a5271a
            ffi.cast('uint32_t *',template+0x70)[0]=u32(entity,12)
            ffi.cast('uint16_t *',template+0x74)[0]=1
            template[0x7a],template[0x7b],template[0x7c]=2,1,5
            record,count=ffi.string(template,128),0
        else
            assert(read(row.address,128,true)==record,'Query changed during snapshot')
            assert(u32(record,0x68)==0x05a5271a and u32(record,0x70)==u32(entity,12), 'Query identity mismatch')
            assert(record:byte(0x7b)==2 and record:byte(0x7c)==1 and record:byte(0x7d)==5,'Unsupported query type')
            assert(u16(record,0x74)==1 and u16(record,0x76)<=1,'Unsupported query capacity')
            if s.stage==3 then
                assert(record:sub(9,16)==string.rep('\0',8) and u32(record,0x6c)==0,
                    'Unsupported retained query options')
            end
            count=u16(record,0x76)
        end
        local hit=read(row.hit_address,44)
        s.hits[#s.hits+1]={slot=i-1,address=row.hit_address,bytes=hit,
            count=count,position=s.rebuild_queries and {0,0,0} or vector(hit,0),normal_z=number(hit,20),
            unit=u32(hit,28),actor=u32(hit,32),record=record}
    end
    local override=lookup(read(manager+0x547c70,20),id,64)
    local settings
    if override and override~=INVALID then
        assert(override<8,'Unsupported settings override')
        settings=read(manager+0x547d24+override*0x354,852)
    else
        local component=pointer(read(owner+0xf12bb8,8))
        -- This resource's two-slot map is verified at runtime, not assumed index zero.
        local map=read(component,32)
        local index
        for slot=0,1 do
            if map:sub(slot*16+1,slot*16+8)==entity:sub(1,8) then index=u32(map,slot*16+8) end
        end
        assert(index and index<1,'Unsupported AvatarComponent map')
        settings=read(component+32+index*852,852)
    end
    local angle=number(settings,0x98)
    assert(angle>0 and angle<90,'Unsupported surface angle')
    s.normal_threshold=f32(math.cos(f32(angle*f32(math.pi/180))))
    local movement=global(0x3326558)
    local mi=lookup(read(movement+0x48a0,20),id,1048576)
    assert(mi and mi~=INVALID and mi<8192,'Movement record unavailable')
    local move=read(pointer(read(movement+0x48c8,8))+mi*132,132)
    local mover=read(pointer(read(movement+0x48d0,8))+mi*164,164)
    local ground=bit.band(u32(flags,8),4)==0 and bit.band(u32(flags,12),0x26)==0 and move:byte(16)==0
    s.max_height=number(settings,ground and 0x104 or 0x108)
    s.ground=ground
    assert(s.max_height>0 and s.max_height<=3,'Unsupported vault height')
    s.native=assert(api.native(game,exe),'Native validation unavailable')
    s.unit=u32(entity,12);s.mover_name=u32(mover,76)
    s.ground_reach=number(settings,0x10c)
    s.root=s.native.mover_position(s.unit,s.mover_name)
    assert(s.root and finite(s.root[1]) and finite(s.root[2]) and finite(s.root[3]),'Mover position unavailable')
    local camera=vector(read(global(0x346d560)+0x1c,12),0)
    camera[3]=0
    local direction=normalize(camera)
    if bit.band(u32(flags,8),0x8000)~=0 then
        -- A6B790 uses this entity's bit 79 to choose its motion direction.
        assert(u32(read(manager+ai*0x1238+0x53e15c,4),0)==id,'Direction state identity mismatch')
        direction=normalize(vector(read(manager+0x150+ai*0xa7aec+171698*4,12),0))
    end
    if not direction then return nil,'waiting_for_direction' end
    s.direction=direction
    s.entity=entity_address
    s.query_bytes=epoch
    return s
end

-- Reuse the native exit validator, then expose just one validated result to the
-- existing selector. Normal metadata is preferred; fallback is manual only.
function M.plan(s,trace)
    if not s or not s.manual then return {} end
    local fallback,chosen
    for _,hit in ipairs(s.hits) do
        local height=f32(hit.position[3]-s.root[3])
        local row
        if trace then
            row={slot=hit.slot,count=hit.count,unit=hit.unit,normal_z=hit.normal_z,height=height,
                normal_threshold=s.normal_threshold,max_height=s.max_height,min_height=s.min_height,
                position=hit.position,source_height=number(hit.record,72)-s.root[3],
                target_height=number(hit.record,100)-s.root[3]}
            trace[#trace+1]=row
        end
        local reason
        if hit.count~=1 or hit.unit==0 then reason='no_hit'
        elseif not finite(hit.normal_z) or hit.normal_z<=s.normal_threshold then reason='surface_angle'
        elseif s.min_height and height<s.min_height then reason='below_ledge_minimum'
        elseif height>s.max_height then reason='height'
        else
            local actor=s.native.actor(hit.actor)
            assert(actor and type(actor.valid)=='boolean','Actor validation unavailable')
            local speed=actor.motion_squared or 0
            assert(finite(speed) and speed>=0,'Invalid actor motion')
            if not actor.valid or speed<=1 then
                local veto=actor.valid and bit.band(actor.flags,0x100000)~=0
                if row then row.actor_valid=actor.valid;row.motion_squared=speed;row.metadata_veto=veto end
                if not veto or not fallback then
                    local exit=s.native.exit(s.entity,hit.position,s.direction)
                    assert(exit==3 or exit==4 or exit==5,'Unsupported exit result')
                    if row then row.exit=exit end
                    if exit~=5 then
                        reason=veto and 'metadata_fallback' or 'accepted'
                        if veto then fallback=hit else chosen=hit end
                    else reason='native_exit' end
                else reason='fallback_already_found' end
            else
                reason='actor_motion'
                if row then row.actor_valid=actor.valid;row.motion_squared=speed end
            end
        end
        if row then row.result=reason end
        if chosen then break end
    end
    local metadata=false
    if not chosen then chosen=fallback;metadata=chosen~=nil end
    if not chosen then return {} end
    local writes={}
    for _,hit in ipairs(s.hits) do
        local original=hit.bytes:sub(29,36)
        local replacement
        if hit==chosen then
            replacement=metadata and pair(hit.unit,INVALID) or original
        elseif hit.slot<chosen.slot and hit.count==1 and hit.unit~=0 then
            replacement=pair(0,hit.actor)
        else replacement=original end
        if replacement~=original then
            writes[#writes+1]={address=hit.address+28,before=original,after=replacement}
        end
    end
    return writes,{slot=chosen.slot,metadata=metadata}
end

function M.restore(api,pending)
    if not pending or not M.same_epoch(api,pending.snapshot) then return true end
    for i=#pending.writes,1,-1 do
        local w=pending.writes[i]
        if api.read(w.address,#w.after)==w.after then
            if not api.write(w.address,w.before) or api.read(w.address,#w.before)~=w.before then return false end
        end
    end
    return true
end

-- Stage 2 is inside native frame processing, which a Lua update can miss
-- entirely. At stage 3, cast the retained local query shapes again into private
-- storage, then let the original driver consume one freshly validated result.
-- A8A140's ten-query geometry, reconstructed privately from a successful fresh
-- A8A710 approach. Calling the producer itself would modify the shared scheduler.
function M.reproject(s,fresh)
    if type(fresh)~='string' or #fresh~=0x2b0 or u32(fresh,4)~=1
        or u32(fresh,684)~=u32(s.controller_bytes,684) or #s.hits~=10 then
        return nil,'unsupported_fresh_approach'
    end
    for offset=488,528,4 do
        if not finite(number(fresh,offset)) then return nil,'unsupported_fresh_approach' end
    end
    local first,last,direction=vector(fresh,488),vector(fresh,500),vector(fresh,520)
    local span,width=number(fresh,512),number(fresh,516)
    local dx,dy,dz=f32(last[1]-first[1]),f32(last[2]-first[2]),f32(last[3]-first[3])
    local length=f32(math.sqrt(f32(f32(f32(dy*dy)+f32(dx*dx))+f32(dz*dz))))
    local norm=direction[1]^2+direction[2]^2+direction[3]^2
    if span<=0.1 or span>3.5 or width<=0 or width>1 or length<0.05 or length>2
        or math.abs(norm-1)>0.001 or math.abs(direction[3])>0.001
        or not s.native.query_basis then return nil,'unsupported_fresh_approach' end
    local matrix=s.native.query_basis(direction)
    if type(matrix)~='string' or #matrix~=64 then return nil,'unsupported_query_basis' end
    -- Native forward/up basis must remain horizontal and orthonormal. Ignore
    -- its translation, which each query below replaces explicitly.
    local expected={direction[2],-direction[1],0,0,direction[1],direction[2],0,0,0,0,1,0}
    for i,want in ipairs(expected) do
        local actual=number(matrix,(i-1)*4)
        if not finite(actual) or math.abs(actual-want)>0.001 then return nil,'unsupported_query_basis' end
    end
    local depth=f32(f32(length/10)*0.5)
    local near,far={},{}
    for axis=1,3 do
        local shift=axis==3 and -f32(0.05) or 0
        near[axis]=f32(f32(f32(depth*direction[axis])+first[axis])+shift)
        far[axis]=f32(f32(last[axis]-f32(depth*direction[axis]))+shift)
    end
    local records={}
    for i,hit in ipairs(s.hits) do
        if hit.slot~=i-1 or #hit.record~=128 then return nil,'unsupported_fresh_approach' end
        local record=ffi.new('uint8_t[128]');ffi.copy(record,hit.record,128)
        ffi.copy(record+16,matrix,64)
        local source,target=ffi.cast('float *',record+64),ffi.cast('float *',record+92)
        local t=f32(hit.slot/9)
        for axis=1,3 do
            local start=f32(f32(near[axis]*f32(1-t))+f32(far[axis]*t))
            source[axis-1]=start
            target[axis-1]=axis==3 and f32(f32(-span+start)+f32(f32(0.05)+f32(0.05))) or start
        end
        source[3]=1
        ffi.copy(record+80,ffi.new('float[3]',{f32(width*0.5),depth,f32(0.05)}),12)
        records[i]=ffi.string(record,128)
    end
    for i,record in ipairs(records) do s.hits[i].record=record end
    s.controller_bytes=fresh;s.reprojected=true
    return true
end

function M.refresh(s,state)
    local matched,why,fresh,code=s.native.context_matches(s.controller_bytes)
    state.last_approach_reason=why or (matched and 'matched' or 'unknown')
    state.last_approach_code=code
    if s.rebuild_queries then
        -- No shared descriptor survives, so neither an old hit count nor old
        -- geometry may authorize a cast, including the raised-top fallback.
        if not fresh or (not matched and why~='native_approach_geometry_changed') then
            return nil,'fresh_approach_unavailable',why
        end
        matched,why=M.reproject(s,fresh)
        if matched then
            state.query_rebuilds=(state.query_rebuilds or 0)+1
            state.context_reprojections=(state.context_reprojections or 0)+1
        end
    elseif not matched and why=='native_approach_geometry_changed' and fresh then
        matched,why=M.reproject(s,fresh)
        if matched then state.context_reprojections=(state.context_reprojections or 0)+1 end
    end
    if not matched then
        return nil,why or 'native_approach_changed_or_blocked'
    end
    local originals={}
    for i,hit in ipairs(s.hits) do
        originals[i]=hit.bytes
        if s.rebuild_queries or hit.count==1 then
            -- Retained geometry must remain near and in front of this avatar.
            -- A fresh cast prevents old hits from surviving removed obstacles.
            for _,offset in ipairs({64,92}) do
                local v=vector(hit.record,offset)
                local dx,dy=v[1]-s.root[1],v[2]-s.root[2]
                if dx*dx+dy*dy>2.25 or math.abs(v[3]-s.root[3])>5
                    or dx*s.direction[1]+dy*s.direction[2]<-0.15 then
                    return nil,'retained_query_out_of_reach'
                end
            end
            local bytes,count=s.native.refresh_query(hit.record,s.world)
            assert(type(bytes)=='string' and #bytes==44 and (count==0 or count==1),'Invalid refreshed query')
            state.fresh_queries=(state.fresh_queries or 0)+1
            hit.bytes,hit.count=bytes,count
            hit.position,hit.normal_z=vector(bytes,0),number(bytes,20)
            hit.unit,hit.actor=u32(bytes,28),u32(bytes,32)
        end
    end
    return originals
end

-- Read-only, fresh native probes decide whether an input window needs any
-- assistance. Ordinary candidates take priority. Nothing is slowed or changed
-- merely because Space was pressed, or because old retained hits look usable.
local function assist_candidate(api,game,exe,state,owner)
    -- Match the main query path's handling of transient unavailable snapshots.
    -- Native validation errors after a snapshot still reach loader cleanup.
    local ok,s,why=pcall(M.snapshot,api,game,exe,nil,true)
    if not ok then state.candidate_error=tostring(s);return nil,'candidate_snapshot_unavailable' end
    if not s or s.stage~=3 then return nil,why or 'waiting_for_consumed_query' end
    if api.distance(s.entity,owner.entity)~=0 then return nil,'candidate_identity_changed' end
    local originals,reason,approach_reason=M.refresh(s,state)
    local raised_fresh
    if not originals and s.ground and math.abs(s.max_height-1.95)<0.001
        and s.native.raised_approach and (reason=='native_approach_blocked'
            or reason=='native_approach_geometry_changed' or reason=='retained_query_out_of_reach'
            or reason=='fresh_approach_unavailable' and approach_reason=='native_approach_blocked') then
        local fresh,why=s.native.raised_approach(s.controller_bytes,s.unit,s.mover_name,s.direction,s.ground_reach)
        if not fresh then return nil,why or 'raised_approach_unavailable' end
        local ready;ready,why=M.reproject(s,fresh)
        if not ready then return nil,why end
        raised_fresh=fresh
        state.raised_approach_rebuilds=(state.raised_approach_rebuilds or 0)+1
        reason='fresh_raised_approach'
    end
    -- A higher-top discovery cast does not consume retained hits. Requiring
    -- the original low-height approach to succeed first makes that discovery
    -- circular. Only this private, bounded search may continue on a context
    -- rejection; ordinary/slope retries require matched or freshly rebuilt geometry.
    if not originals and reason~='native_approach_blocked' and reason~='native_approach_geometry_changed'
        and reason~='native_approach_changed_or_blocked' and not raised_fresh then return nil,reason end
    local trace={time=api.time(),root=s.root,direction=s.direction,ground=s.ground,
        context=originals and (s.reprojected and 'reprojected' or 'matched') or reason,
        passes={ordinary={},slope={},raised={}}}
    state.candidate_trace=trace
    local baseline=s.normal_threshold
    local selected
    if originals then
        local _,ordinary=M.plan(s,trace.passes.ordinary)
        if ordinary then return nil,'ordinary_candidate_retained' end
        s.normal_threshold=f32(math.cos(f32(65*f32(math.pi/180))))
        _,selected=M.plan(s,trace.passes.slope)
    end
    local kind='slope'
    if not selected and s.ground and math.abs(s.max_height-1.95)<0.001 then
        s.normal_threshold=baseline;s.max_height=2.5;s.min_height=0.5;kind='ledge'
        for _,hit in ipairs(s.hits) do
            -- Raise only the start of a private downward cast; leave its end,
            -- shape, filter, ignored unit and returned normals untouched.
            local start=vector(hit.record,64);local target=vector(hit.record,92)
            local dx,dy=start[1]-s.root[1],start[2]-s.root[2]
            local tx,ty=target[1]-s.root[1],target[2]-s.root[2]
            if dx*dx+dy*dy>2.25 or tx*tx+ty*ty>2.25 or start[3]<target[3]
                or math.abs(start[3]-s.root[3])>5 or math.abs(target[3]-s.root[3])>5
                or dx*s.direction[1]+dy*s.direction[2]<-0.15
                or tx*s.direction[1]+ty*s.direction[2]<-0.15 then return nil,'raised_query_out_of_reach' end
            -- Anchor the discovery ceiling to the current native mover, not
            -- the potentially clipped/low retained approach ceiling. Reserve
            -- space for the full box over a top at the allowed surface angle.
            local size=vector(hit.record,80)
            for _,dimension in ipairs(size) do
                if dimension<=0 or dimension>0.5 then return nil,'unsupported_probe_extent' end
            end
            local extent=math.abs(number(hit.record,24))*size[1]
                +math.abs(number(hit.record,40))*size[2]+math.abs(number(hit.record,56))*size[3]
            local horizontal=0
            for axis=0,2 do
                local x,y=number(hit.record,16+axis*16),number(hit.record,20+axis*16)
                horizontal=horizontal+math.sqrt(x*x+y*y)*size[axis+1]
            end
            if not finite(extent) or extent<=0 or extent>0.25
                or not finite(horizontal) or horizontal<=0 or horizontal>0.5
                or baseline<0.7 or baseline>1 then return nil,'unsupported_probe_extent' end
            local clearance=extent+horizontal*math.sqrt(math.max(0,1-baseline*baseline))/baseline+0.01
            local ceiling=f32(s.root[3]+s.max_height+clearance)
            if target[3]>=ceiling then return nil,'raised_query_out_of_reach' end
            local raised=ffi.string(ffi.new('float[1]',ceiling),4)
            local record=hit.record:sub(1,72)..raised..hit.record:sub(77)
            local b,count=s.native.refresh_query(record,s.world)
            assert(type(b)=='string' and #b==44 and (count==0 or count==1),'Invalid raised query')
            state.raised_queries=(state.raised_queries or 0)+1
            hit.bytes,hit.count=b,count;hit.position,hit.normal_z=vector(b,0),number(b,20)
            hit.unit,hit.actor=u32(b,28),u32(b,32)
            hit.record=record -- Private trace reports the cast actually performed.
        end
        _,selected=M.plan(s,trace.passes.raised)
        state.raised_trace=trace
        if not originals then state.raised_context_fallbacks=(state.raised_context_fallbacks or 0)+1 end
    end
    if not selected then return nil,'no_usable_assisted_candidate' end
    local hit=s.hits[selected.slot+1]
    local dx,dy=hit.position[1]-s.root[1],hit.position[2]-s.root[2]
    if dx*dx+dy*dy>2.25 or dx*s.direction[1]+dy*s.direction[2]<-0.15 then return nil,'candidate_out_of_reach' end
    if raised_fresh then
        local fresh=s.native.raised_approach(s.controller_bytes,s.unit,s.mover_name,s.direction,s.ground_reach)
        if type(fresh)~='string' or #fresh~=0x2b0 or u32(fresh,4)~=1
            or u32(fresh,684)~=u32(raised_fresh,684) then return nil,'raised_context_changed_before_commit' end
        for offset=488,528,4 do
            local v=number(fresh,offset)
            if not finite(v) or math.abs(v-number(raised_fresh,offset))>0.02 then
                return nil,'raised_context_changed_before_commit'
            end
        end
    elseif s.reprojected and not s.native.context_matches(s.controller_bytes) then
        return nil,'native_context_changed_before_commit'
    end
    for _,guard in ipairs(s.guards) do
        if api.read(guard.address,#guard.bytes)~=guard.bytes then return nil,'candidate_changed' end
    end
    state.candidate_height=hit.position[3]-s.root[3]
    state.candidate_normal_z=hit.normal_z
    return kind,kind=='ledge' and 'validated_raised_top' or 'validated_steep_candidate'
end

function M.assist_candidate(api,game,exe,state,owner)
    local previous=state.candidate_trace
    local kind,reason=assist_candidate(api,game,exe,state,owner)
    state.candidate_results=state.candidate_results or {}
    state.candidate_results[reason]=(state.candidate_results[reason] or 0)+1
    if state.candidate_trace~=previous then state.candidate_trace.result=reason end
    return kind,reason
end

function M.retry_consumed(api,s,state)
    -- The native selectors read shared scheduler counts. Private rebuilding
    -- is discovery-only; never let foreign counts reach local consumption.
    if s.rebuild_queries then return true,'retained_query_reused',false end
    local now=api.time()
    if state.last_retry_at and now-state.last_retry_at<0.1 then
        return true,'waiting_for_retry_interval',false
    end
    state.last_retry_at=now
    local originals,reason=M.refresh(s,state)
    if not originals then return true,reason,false end
    local _,selected=M.plan(s)
    if not selected then return true,'native_vault_checks_retained',true end
    local chosen=s.hits[selected.slot+1]
    local dx,dy=chosen.position[1]-s.root[1],chosen.position[2]-s.root[2]
    if dx*dx+dy*dy>2.25 or dx*s.direction[1]+dy*s.direction[2]<-0.15 then
        return true,'retained_query_out_of_reach',false
    end
    local writes={}
    for i,hit in ipairs(s.hits) do
        local before=originals[i]
        if hit==chosen then
            local after=hit.bytes
            if selected.metadata then after=after:sub(1,32)..pair(INVALID,0):sub(1,4)..after:sub(37) end
            if before~=after then writes[#writes+1]={address=hit.address,before=before,after=after} end
        elseif u32(before,28)~=0 then
            writes[#writes+1]={address=hit.address+28,before=before:sub(29,36),after=pair(0,u32(before,32))}
        end
    end
    writes[#writes+1]={address=s.controller+4,before=pair(3,0):sub(1,4),after=pair(2,0):sub(1,4)}
    if s.reprojected and not s.native.context_matches(s.controller_bytes) then
        return true,'native_context_changed_before_commit',false
    end
    for _,g in ipairs(s.guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return true,'query_changed_before_commit',false end
    end
    local pending={snapshot=s,writes={}}
    state.pending=pending
    local function rollback(reason)
        local restored=M.restore(api,pending)
        state.pending=nil
        return false,restored and reason or 'query_restore_failed',false
    end
    for _,w in ipairs(writes) do
        if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes
            or api.read(w.address,#w.before)~=w.before or not api.writable_data(w.address,#w.after) then
            local restored=M.restore(api,pending);state.pending=nil
            return restored,restored and 'query_changed_before_commit' or 'query_restore_failed',false
        end
        pending.writes[#pending.writes+1]=w
        if not api.write(w.address,w.after) or api.read(w.address,#w.after)~=w.after then
            -- Same bytewise partial-write recovery as the early query path.
            local current=api.read(w.address,#w.before)
            if current and current~=w.before and current~=w.after and M.same_epoch(api,s) then
                local partial=true
                for j=1,#current do
                    if current:byte(j)~=w.before:byte(j) and current:byte(j)~=w.after:byte(j) then partial=false end
                end
                if partial and (not api.write(w.address,w.before) or api.read(w.address,#w.before)~=w.before) then
                    return rollback('query_restore_failed')
                end
            end
            return rollback('query_write_failed')
        end
    end
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes then
        return rollback('query_changed_before_retry')
    end
    state.prepared=(state.prepared or 0)+1
    if selected.metadata then state.metadata_fallbacks=(state.metadata_fallbacks or 0)+1 end
    state.retry_calls=(state.retry_calls or 0)+1
    if s.reprojected then state.reprojected_retries=(state.reprojected_retries or 0)+1 end
    if s.prior_step_report then state.step_report_retries=(state.step_report_retries or 0)+1 end
    local called,reason=pcall(s.native.retry,s.controller)
    if not called then return rollback('native_retry_failed: '..tostring(reason)) end
    local started=false
    if M.same_epoch(api,s) then
        local flags=api.read(s.flags_address,24)
        started=flags and bit.band(u32(flags,12),0x200)~=0 or false
    end
    local restored=M.restore(api,pending);state.pending=nil
    if not restored then return false,'query_restore_failed',false end
    if started then state.native_starts=(state.native_starts or 0)+1 end
    if started and s.reprojected then state.reprojected_starts=(state.reprojected_starts or 0)+1 end
    if started and s.prior_step_report then state.step_report_starts=(state.step_report_starts or 0)+1 end
    return true,started and 'native_local_vault_started' or 'native_local_retry_rejected',started
end

function M.apply(api,game,exe,state)
    if state.pending then
        if not M.restore(api,state.pending) then return false,'query_restore_failed',false end
        state.pending=nil
    end
    if M.assistance then
        local accepted,reason=M.assistance.step(api,game,exe,state)
        if not accepted then return false,reason,false end
    end
    local ok,s,reason=pcall(M.snapshot,api,game,exe,state)
    if not ok then return true,'waiting_for_game_data: '..tostring(s),false end
    if not s then return true,reason,false end
    state.observed_queries=(state.observed_queries or 0)+1
    if s.stage==3 then
        local called,accepted,why,active=pcall(M.retry_consumed,api,s,state)
        if not called then
            local restored=M.restore(api,state.pending);state.pending=nil
            return false,restored and 'validation_failed: '..tostring(accepted) or 'query_restore_failed',false
        end
        state.last_retry_reason=why
        return accepted,why,active
    end
    local planned,writes,selected=pcall(M.plan,s)
    if not planned then return false,'validation_failed: '..tostring(writes),false end
    if #writes==0 then return true,'native_vault_checks_retained',true end
    for _,g in ipairs(s.guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return true,'query_changed_before_commit',false end
    end
    local pending={snapshot=s,writes={}}
    for _,w in ipairs(writes) do
        if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes
            or api.read(w.address,8)~=w.before or not api.writable_data(w.address,8) then
            local restored=M.restore(api,pending)
            return restored,restored and 'query_changed_before_commit' or 'query_restore_failed',false
        end
        -- Include the attempted write in rollback: a failed API may write partially.
        pending.writes[#pending.writes+1]=w
        if not api.write(w.address,w.after) or api.read(w.address,8)~=w.after then
            local current=api.read(w.address,8)
            if current and current~=w.before and current~=w.after and M.same_epoch(api,s) then
                local partial=true
                for j=1,8 do
                    if current:byte(j)~=w.before:byte(j) and current:byte(j)~=w.after:byte(j) then partial=false end
                end
                if partial and (not api.write(w.address,w.before) or api.read(w.address,8)~=w.before) then
                    M.restore(api,pending)
                    return false,'query_restore_failed',false
                end
            end
            local restored=M.restore(api,pending)
            return false,restored and 'query_write_failed' or 'query_restore_failed',false
        end
    end
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes then
        local restored=M.restore(api,pending)
        return restored,restored and 'query_changed_after_commit' or 'query_restore_failed',false
    end
    state.pending=pending
    state.prepared=(state.prepared or 0)+1
    if selected.metadata then state.metadata_fallbacks=(state.metadata_fallbacks or 0)+1 end
    state.last_slot=selected.slot
    return true,selected.metadata and 'local_manual_metadata_fallback_prepared' or 'local_manual_alternative_prepared',true
end
function M.stop(api,game,exe,state)
    local queries=M.restore(api,state.pending)
    if queries then state.pending=nil end
    local slopes=not M.assistance or M.assistance.stop(api,game,exe,state)
    return queries and slopes
end
return M
