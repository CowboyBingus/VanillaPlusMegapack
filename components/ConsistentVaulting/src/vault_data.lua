local ffi, bit = require('ffi'), require('bit')
local M = {}
local INVALID = 0xffffffff
-- Fields decode from the string's bytes with arithmetic: no cdata, cast or copy
-- per field.
local function u32(b,o)
    local b0,b1,b2,b3=b:byte(o+1,o+4)
    return ((b3*256+b2)*256+b1)*256+b0
end
local function u16(b,o)
    local b0,b1=b:byte(o+1,o+2)
    return b1*256+b0 -- lint-ok: R14 slope_assist.lua decodes alike; each module loads and is tested alone
end
-- The float with bits w. A NaN loaded through a float cdata can become a
-- non-number value in the game's NaN-tagged LuaJIT; decoded here it is a plain
-- NaN.
local function float_bits(w)
    local e,m=bit.band(bit.rshift(w,23),0xff),bit.band(w,0x7fffff)
    local v
    if e==0xff then v=m==0 and math.huge or 0/0 elseif e==0 then v=m*2^-149 else v=(m+0x800000)*2^(e-150) end
    if w>=0x80000000 then return -v end
    return v
end
local function number(b,o) return float_bits(u32(b,o)) end
local function finite(n) return n == n and math.abs(n) < 100000 end
-- n rounded to float32 through one reused cell (its inputs are finite).
local rounding=ffi.new('float[1]')
local function f32(n) rounding[0]=n;return rounding[0] end
-- The low 32 bits of a*b for 32-bit a and b, exact in doubles: no 64-bit cdata.
local function low_product(a,b)
    local a_low,b_low=a%65536,b%65536
    return (a_low*b_low+(((a-a_low)/65536*b_low+a_low*(b-b_low)/65536)%65536)*65536)%4294967296
end
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

-- Held writes: the stage-2 writes a previous check prepared, still in place.
-- The next check reads its hits as the restore would leave them, so its plan
-- is the one it would make after restoring. Writes start at a hit's +28.
local HIT_PAIR=28
local function unheld(held,bytes,address,offset)
    for _,w in ipairs(held.writes) do
        local finish=offset+#w.after
        if w.address==address+offset and bytes:sub(offset+1,finish)==w.after then
            return bytes:sub(1,offset)..w.before..bytes:sub(finish+1)
        end
    end
    return bytes
end
local function held_hit(held,bytes,address) return unheld(held,bytes,address,HIT_PAIR) end
local function held_controller(held,bytes,address)
    for slot=0,9 do bytes=unheld(held,bytes,address,0x30+44*slot+HIT_PAIR) end
    return bytes
end

-- Snapshot reads: each is complete or raises, and is a guard (verified again
-- before writes); epoch guards also decide whether held or prepared writes
-- still belong to this batch (M.same_epoch).
local function record(s,address,bytes,epoch)
    local guard={address=address,bytes=bytes}
    s.guards[#s.guards+1]=guard
    if epoch then s.epoch[#s.epoch+1]=guard end
    return guard
end
local function read(api,s,address,size,epoch)
    local bytes = assert(api.read(address,size),'Game data unavailable')
    assert(#bytes==size,'Short game read')
    record(s,address,bytes,epoch)
    return bytes
end
-- A guard read through a view holds the restored bytes; it is checked through
-- the same view (keeps) while the writes stay held.
local function read_held(api,s,held,view,address,size)
    local bytes = assert(api.read(address,size),'Game data unavailable')
    assert(#bytes==size,'Short game read')
    local guard=record(s,address,bytes)
    if held then bytes=view(held,bytes,address);guard.bytes=bytes;guard.view=view end
    return bytes
end
local function pointer(api,bytes,offset)
    return assert(api.pointer(bytes,offset),'Game pointer unavailable')
end
local function global(api,s,game,rva,epoch) return pointer(api,read(api,s,game+rva,8,epoch)) end
-- The value stored for key in a game hash map whose header bytes are given.
local function lookup(api,s,header,key,limit)
    local capacity,empty,mult=u32(header,8),u32(header,12),u32(header,16)
    assert(capacity<=limit and capacity>0 and bit.band(capacity,capacity-1)==0,'Unsupported map')
    local data=pointer(api,header)
    -- Keep the low product exact even for a full uint32 key/multiplier.
    -- It does not depend on the probe index, so it is computed once.
    local low=low_product(key,mult)
    for probe=0,math.min(capacity,128)-1 do
        local slot=bit.band(low+probe,capacity-1)
        local row=read(api,s,data+slot*8,8)
        if u32(row,0)==key then return u32(row,4) end
        if u32(row,0)==empty then return nil end
    end
    return nil
end

-- Counted per stage reached, as diagnostics.
local function count_stage(state,stage)
    if not state then return end
    local key='stage_'..stage
    state[key]=(state[key] or 0)+1
end

-- The mission gate, first in every snapshot. Outside a mission a check stops
-- here, so it must not allocate: the mode pointer and the mode record are read
-- with api.read_into into one reused buffer and decode in place. Their
-- addresses take the api's address values, made once per game base and per
-- mode record address. True in a mission; a snapshot that goes on records both
-- reads as its first guards (mission_guards).
local gate=ffi.new('uint8_t[80]')
local gate_words,gate_record=ffi.cast('uint32_t *',gate),gate+8
local GATE_POINTER=ffi.typeof('uint8_t *')
local gate_game,gate_global,gate_mode,gate_mode_address
local function mission_gate(api,game)
    if game~=gate_game then gate_game,gate_global=game,game+0x33266a0 end
    assert(api.read_into(gate_global,8,gate),'Game data unavailable')
    -- The mode record's address (api.pointer's rule: at least 0x10000, below 2^47).
    local high=gate_words[1]
    local mode=high<0x8000 and high*4294967296+gate_words[0]
    assert(mode and mode>=0x10000,'Game pointer unavailable')
    if mode~=gate_mode then
        gate_mode,gate_mode_address=mode,type(game)=='number' and mode or ffi.cast(GATE_POINTER,mode)
    end
    assert(api.read_into(gate_mode_address,0x44,gate_record),'Game data unavailable')
    return gate_words[4]~=0 and gate_words[18]>=1 and gate_words[18]<=7
end
local function mission_guards(s)
    record(s,gate_global,ffi.string(gate,8))
    record(s,gate_mode_address,ffi.string(gate_record,0x44))
end

-- The local player's unit reference (in a mission), else nil and why.
local function local_unit(api,s,game)
    local pm=global(api,s,game,0x3326468,true)
    local counts=read(api,s,pm+0x84,8)
    assert(u32(counts,0)<=4 and u32(counts,4)<=4,'Unsupported player count')
    if u32(counts,0)==0 or u32(counts,4)==0 then return nil,'waiting_for_local_player' end
    local player=read(api,s,pointer(api,read(api,s,pm+0xe8,8,true)),24,true)
    if bit.band(player:byte(21),1)==0 then return nil,'waiting_for_local_player' end
    local unit_ref=u32(read(api,s,pm+0x3a8,4,true),0)
    if unit_ref==0x7fff then return nil,'waiting_for_local_avatar' end
    return unit_ref
end

-- The local avatar entity of unit_ref: its address and bytes, else nil and why.
local function local_entity(api,s,owner,unit_ref)
    local ei=lookup(api,s,read(api,s,owner+0xf22ec8,20),unit_ref,1048576)
    if not ei or ei==INVALID then return nil,'waiting_for_local_avatar' end
    assert(ei<262144,'Unsupported entity index')
    local entity_address=owner+0xf32f18+ei*24
    local entity=read(api,s,entity_address,24,true)
    -- Resource 0x4d1c334d294dfa97, kept as bytes to avoid floating-point hashing.
    assert(entity:sub(1,8)=='\151\250\077\041\077\051\028\077','Unsupported avatar resource')
    if bit.band(entity:byte(21),1)==0 then return nil,'waiting_for_local_avatar' end
    return entity_address,entity
end

-- The avatar index of id, checked against the avatar count and the registry.
local function avatar_index(api,s,manager,id,entity)
    local ai=lookup(api,s,read(api,s,manager+0xf8,20),id,64)
    if not ai or ai==INVALID then return nil end
    local n=u32(read(api,s,manager+0x6c,4),0)
    assert(n<=8 and ai<n,'Unsupported avatar index')
    assert(read(api,s,pointer(api,read(api,s,manager+0x110+ai*8,8,true)),24,true)==entity,'Avatar registry mismatch')
    return ai
end

-- The epoch's query IDs (and, at stage 2, its phase) become epoch guards; true
-- when the manual vault input is held.
local function manual_input(api,s,manager,ai)
    -- The late retry temporarily returns stage 3 to stage 2. The query IDs,
    -- entity and records still define the epoch across that native call.
    read(api,s,s.controller+8,40,true)
    if s.stage==2 then read(api,s,s.controller+4,4,true) end
    s.input_address=manager+0x150+ai*0xa7aec+0x1b68+14*32
    s.manual_bytes=read(api,s,s.input_address,1)
    if s.manual_bytes:byte()==0 then return false end
    s.manual=true
    return true
end

-- Match A88020/A88160 before re-entering the original local driver.
local function driver_refuses(flags,controller)
    local climbing=bit.band(u32(flags,12),0x200)~=0
    local excluded=bit.band(u32(flags,0),0x404000)~=0
        or bit.band(u32(flags,4),0x8000000)~=0
        or bit.band(u32(flags,8),0x20084000)~=0
        or bit.band(u32(flags,12),0x5181c)~=0
        or bit.band(u32(flags,16),9)~=0
    return climbing or excluded or bit.band(u32(flags,0),2)==0 or controller:byte(0x215)~=0
end

-- The local controller (as the restore of held writes would leave it) and the
-- avatar's movement flags; nil at stage 3 while the native driver would refuse
-- a retry.
local function controller_flags(api,s,held,manager,ai)
    local controller=read_held(api,s,held,held_controller,s.controller,0x2b0)
    s.controller_bytes=controller
    s.flags_address=manager+ai*0x1238+0x53e880
    local flags=read(api,s,s.flags_address,24)
    if s.stage~=3 then return flags end
    -- +532 is pending climb readiness. +533 only reports an automatic
    -- step; A8A710 can retain it across later failed detections. A88160
    -- does not use that report as an eligibility veto. Never clear it.
    s.prior_step_report=controller:byte(0x216)~=0
    if driver_refuses(flags,controller) then return nil end
    return flags
end

-- The query scheduler, its job table and query count. At stage 3, Lua runs
-- after consumption: retained descriptors and private discovery queries need
-- an idle scheduler (else nil and why).
local function query_scheduler(api,s,game,manager)
    local scheduler=pointer(api,read(api,s,manager+0x28,8,true))
    local jobs=read(api,s,scheduler+0x40000,100,true)
    local total=u32(jobs,0)
    if s.stage~=3 then
        assert(total>0 and total<=2048,'Unsupported query count')
        return scheduler,jobs,total
    end
    if total~=0 then return nil,'waiting_for_idle_query_scheduler' end
    for job=0,7 do
        if u32(jobs,12+job*12)~=1 then return nil,'waiting_for_query_workers' end
    end
    s.world=global(api,s,game,0x346bfa0,true)
    return scheduler,jobs,total
end

-- True when a completed worker job covers query.
local function completed(jobs,query)
    local done=false
    for job=0,7 do
        local start,finish,state=u32(jobs,4+job*12),u32(jobs,8+job*12),u32(jobs,12+job*12)
        if query-1>=start and query-1<finish and state==1 then done=true end
    end
    return done
end

-- The scheduler record of query for hit slot (address, bytes, hit address),
-- else nil and why. Ownership must be established for the whole batch before
-- any shared descriptor becomes a guard, so this read is not one. Reused
-- records are never our epoch: only discovery at stage 3 rebuilds them.
local function owned_record(api,s,scheduler,query,slot,discovery)
    local address=scheduler+(query-1)*128
    local record=assert(api.read(address,128),'Game data unavailable')
    assert(#record==128,'Short game read')
    local hit_address=s.controller+0x30+44*slot
    local output=api.pointer(record)
    if not output or api.distance(output,hit_address)~=0 then
        if s.stage~=3 then error('Query output is not local controller data') end
        if discovery~=true then return nil,'retained_query_reused' end
        s.rebuild_queries=true
    end
    return {address=address,bytes=record,hit_address=hit_address}
end

-- The ten query records of the batch, each owned by its local hit slot, else
-- nil and why.
local function query_records(api,s,epoch,scheduler,jobs,total,discovery)
    local seen,records={},{}
    for slot=0,9 do
        local query=u32(epoch,4+slot*4)
        assert(query>0 and query<=(s.stage==3 and 2048 or total) and not seen[query],'Unsupported query ID')
        seen[query]=true
        if s.stage==2 and not completed(jobs,query) then return nil,'waiting_for_query_workers' end
        local row,why=owned_record(api,s,scheduler,query,slot,discovery)
        if not row then return nil,why end
        records[#records+1]=row
    end
    return records
end

-- A9BE10 / 175BA70's fixed query metadata for a rebuilt slot. Geometry is
-- populated only after a successful fresh native approach in M.refresh.
local function query_template(row,entity)
    local template=ffi.new('uint8_t[128]')
    ffi.cast('uintptr_t *',template)[0]=ffi.cast('uintptr_t',row.hit_address)
    ffi.cast('uint32_t *',template+0x68)[0]=0x05a5271a
    ffi.cast('uint32_t *',template+0x70)[0]=u32(entity,12)
    ffi.cast('uint16_t *',template+0x74)[0]=1
    template[0x7a],template[0x7b],template[0x7c]=2,1,5
    return ffi.string(template,128),0
end

-- A slot's own descriptor, verified, and its result count.
local function query_descriptor(api,s,row,entity)
    local record=row.bytes
    assert(read(api,s,row.address,128,true)==record,'Query changed during snapshot')
    assert(u32(record,0x68)==0x05a5271a and u32(record,0x70)==u32(entity,12), 'Query identity mismatch')
    assert(record:byte(0x7b)==2 and record:byte(0x7c)==1 and record:byte(0x7d)==5,'Unsupported query type')
    assert(u16(record,0x74)==1 and u16(record,0x76)<=1,'Unsupported query capacity')
    if s.stage==3 then
        assert(record:sub(9,16)==string.rep('\0',8) and u32(record,0x6c)==0,
            'Unsupported retained query options')
    end
    return record,u16(record,0x76)
end

-- Each slot's descriptor and local hit, read as the restore of held writes
-- would leave it.
local function read_hits(api,s,held,records,entity)
    for i,row in ipairs(records) do
        local record,count
        if s.rebuild_queries then record,count=query_template(row,entity)
        else record,count=query_descriptor(api,s,row,entity) end
        local hit=read_held(api,s,held,held_hit,row.hit_address,44)
        s.hits[#s.hits+1]={slot=i-1,address=row.hit_address,bytes=hit,
            count=count,position=s.rebuild_queries and {0,0,0} or vector(hit,0),normal_z=number(hit,20),
            unit=u32(hit,28),actor=u32(hit,32),record=record}
    end
end

-- The effective settings record: the avatar's override, or the shared
-- component record of its resource.
local function vault_settings(api,s,manager,owner,id,entity)
    local override=lookup(api,s,read(api,s,manager+0x547c70,20),id,64)
    if override and override~=INVALID then
        assert(override<8,'Unsupported settings override')
        return read(api,s,manager+0x547d24+override*0x354,852)
    end
    local component=pointer(api,read(api,s,owner+0xf12bb8,8))
    -- This resource's two-slot map is verified at runtime, not assumed index zero.
    local map=read(api,s,component,32)
    local index
    for slot=0,1 do
        if map:sub(slot*16+1,slot*16+8)==entity:sub(1,8) then index=u32(map,slot*16+8) end
    end
    assert(index and index<1,'Unsupported AvatarComponent map')
    return read(api,s,component+32+index*852,852)
end

-- The cosine of the settings' surface angle, in float32 steps.
local function surface_threshold(settings)
    local angle=number(settings,0x98)
    assert(angle>0 and angle<90,'Unsupported surface angle')
    return f32(math.cos(f32(angle*f32(math.pi/180))))
end

-- The local movement and mover records.
local function movement_records(api,s,game,id)
    local movement=global(api,s,game,0x3326558)
    local mi=lookup(api,s,read(api,s,movement+0x48a0,20),id,1048576)
    assert(mi and mi~=INVALID and mi<8192,'Movement record unavailable')
    local move=read(api,s,pointer(api,read(api,s,movement+0x48c8,8))+mi*132,132)
    local mover=read(api,s,pointer(api,read(api,s,movement+0x48d0,8))+mi*164,164)
    return move,mover
end

-- Ground contact, the vault height it allows and the native mover position.
local function mover_state(api,s,game,exe,settings,flags,move)
    local ground=bit.band(u32(flags,8),4)==0 and bit.band(u32(flags,12),0x26)==0 and move:byte(16)==0
    s.max_height=number(settings,ground and 0x104 or 0x108)
    s.ground=ground
    assert(s.max_height>0 and s.max_height<=3,'Unsupported vault height')
    s.native=assert(api.native(game,exe),'Native validation unavailable')
    s.ground_reach=number(settings,0x10c)
    s.root=s.native.mover_position(s.unit,s.mover_name)
    assert(s.root and finite(s.root[1]) and finite(s.root[2]) and finite(s.root[3]),'Mover position unavailable')
end

-- The horizontal camera direction, or the avatar's own motion direction while
-- its movement flags select it; nil without length.
local function vault_direction(api,s,game,manager,ai,id,flags)
    local camera=vector(read(api,s,global(api,s,game,0x346d560)+0x1c,12),0)
    camera[3]=0
    local direction=normalize(camera)
    if bit.band(u32(flags,8),0x8000)~=0 then
        -- A6B790 uses this entity's bit 79 to choose its motion direction.
        assert(u32(read(api,s,manager+ai*0x1238+0x53e15c,4),0)==id,'Direction state identity mismatch')
        direction=normalize(vector(read(api,s,manager+0x150+ai*0xa7aec+171698*4,12),0))
    end
    return direction
end

-- The local avatar from the mission gate down: owner, entity address and bytes,
-- manager and avatar index, else nil and why.
local function local_avatar(api,s,game)
    if not mission_gate(api,game) then return nil,'waiting_for_mission' end
    mission_guards(s)
    local unit_ref,why=local_unit(api,s,game)
    if not unit_ref then return nil,why end
    local owner=global(api,s,game,0x346bf98,true)
    local entity_address,entity=local_entity(api,s,owner,unit_ref)
    if not entity_address then return nil,entity end
    local manager=global(api,s,game,0x3326d20,true)
    local ai=avatar_index(api,s,manager,u32(entity,8),entity)
    if not ai then return nil,'waiting_for_local_avatar' end
    return owner,entity_address,entity,manager,ai
end
-- The same from the slope snapshot of this check (avatar), which resolved this
-- chain with the same checks: its reads become this snapshot's guards (and
-- epoch guards) as the vault's own reads would, and are verified again before
-- any write like every other guard.
local function slope_avatar(s,avatar)
    for _,g in ipairs(avatar.identity) do record(s,g.address,g.bytes,g.epoch) end
    return avatar.key.owner,avatar.entity,avatar.entity_bytes,avatar.key.manager,avatar.ai
end

-- avatar: the slope snapshot of this check, when it resolved the local avatar
-- in full, else nil.
function M.snapshot(api,game,exe,state,discovery,held,avatar)
    local s = {epoch={},guards={},hits={}}
    local owner,entity_address,entity,manager,ai
    if avatar then owner,entity_address,entity,manager,ai=slope_avatar(s,avatar)
    else owner,entity_address,entity,manager,ai=local_avatar(api,s,game) end
    if not owner then return nil,entity_address end
    local id=u32(entity,8)
    local why
    s.controller=manager+0x53e1b8+ai*0x1238
    assert(u32(read(api,s,s.controller+0x2ac,4,true),0)==id,'Controller identity mismatch')
    local epoch=read(api,s,s.controller+4,44)
    s.stage=u32(epoch,0)
    count_stage(state,s.stage)
    if s.stage~=2 and s.stage~=3 then return nil,'waiting_for_vault_query' end
    if not manual_input(api,s,manager,ai) then return nil,'waiting_for_manual_vault' end
    local flags=controller_flags(api,s,held,manager,ai)
    if not flags then return nil,'native_vault_state_retained' end
    local scheduler,jobs,total=query_scheduler(api,s,game,manager)
    if not scheduler then return nil,jobs end
    local records
    records,why=query_records(api,s,epoch,scheduler,jobs,total,discovery)
    if not records then return nil,why end
    read_hits(api,s,held,records,entity)
    local settings=vault_settings(api,s,manager,owner,id,entity)
    s.normal_threshold=surface_threshold(settings)
    local move,mover=movement_records(api,s,game,id)
    s.unit=u32(entity,12);s.mover_name=u32(mover,76)
    mover_state(api,s,game,exe,settings,flags,move)
    local direction=vault_direction(api,s,game,manager,ai,id,flags)
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

-- Every query write lies in the local controller, inside [controller,
-- controller+0x1e8): the phase at +4 and the ten 44-byte hits from +0x30. One
-- protection query covers a whole commit or restore.
local CONTROLLER_SPAN=0x1e8
local function write_controller(api,controller,writes,field)
    local changes={}
    for i,w in ipairs(writes) do changes[i]={api.distance(w.address,controller),w[field]} end
    return api.write_batch(controller,CONTROLLER_SPAN,changes)
end

-- The first write whose bytes in memory differ from its field, or nil.
local function first_mismatch(api,writes,field)
    for _,w in ipairs(writes) do
        if api.read(w.address,#w[field])~=w[field] then return w end
    end
    return nil
end

-- Writes the original bytes back wherever a write is still in place, with one
-- protection query, and reads each back.
local function restore_in_place(api,pending)
    local back={}
    for i=#pending.writes,1,-1 do
        local w=pending.writes[i]
        if api.read(w.address,#w.after)==w.after then back[#back+1]=w end
    end
    if #back==0 then return true end
    return write_controller(api,pending.snapshot.controller,back,'before') and not first_mismatch(api,back,'before')
end

function M.restore(api,pending)
    if not pending or not M.same_epoch(api,pending.snapshot) then return true end
    return restore_in_place(api,pending)
end

-- A failed write may land in part: a byte mix of the original and the new
-- bytes is ours to undo. False only when undoing it failed.
local function undo_partial(api,s,w)
    local current=api.read(w.address,#w.before)
    if not current or current==w.before or current==w.after or not M.same_epoch(api,s) then return true end
    for j=1,#current do
        local c=current:byte(j)
        if c~=w.before:byte(j) and c~=w.after:byte(j) then return true end
    end
    return api.write(w.address,w.before) and api.read(w.address,#w.before)==w.before
end

-- Writes a commit with one protection query: the epoch, the input and every
-- original are verified first, each write is read back after. pending.writes
-- gets every write before the attempt, so a rollback can undo any of them.
-- Returns nil when all landed, else 'changed' (nothing written: the data
-- changed, or protection was refused as the separate check used to report),
-- 'write' (a write failed) or 'restore' (undoing a partial write failed).
local function commit(api,s,pending,writes)
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes
        or first_mismatch(api,writes,'before') then return 'changed' end
    for _,w in ipairs(writes) do pending.writes[#pending.writes+1]=w end
    local written,landed=write_controller(api,s.controller,writes,'after')
    if not written and landed==0 and not api.writable_data(s.controller,CONTROLLER_SPAN) then return 'changed' end
    local failed=writes[landed+1]
    if written then failed=first_mismatch(api,writes,'after') end
    if not failed then return nil end
    return undo_partial(api,s,failed) and 'write' or 'restore'
end

-- Stage 2 is inside native frame processing, which a Lua update can miss
-- entirely. At stage 3, cast the retained local query shapes again into private
-- storage, then let the original driver consume one freshly validated result.
-- A8A140's ten-query geometry, reconstructed privately from a successful fresh
-- A8A710 approach. Calling the producer itself would modify the shared scheduler.

-- The fresh approach of a complete local controller copy with finite
-- geometry: its endpoints, direction, span, width and length, else nil.
local function fresh_geometry(s,fresh)
    if type(fresh)~='string' or #fresh~=0x2b0 or u32(fresh,4)~=1
        or u32(fresh,684)~=u32(s.controller_bytes,684) or #s.hits~=10 then return nil end
    for offset=488,528,4 do
        if not finite(number(fresh,offset)) then return nil end
    end
    local first,last,direction=vector(fresh,488),vector(fresh,500),vector(fresh,520)
    local dx,dy,dz=f32(last[1]-first[1]),f32(last[2]-first[2]),f32(last[3]-first[3])
    local length=f32(math.sqrt(f32(f32(f32(dy*dy)+f32(dx*dx))+f32(dz*dz))))
    return first,last,direction,number(fresh,512),number(fresh,516),length
end

-- True when span, width, length and a horizontal unit direction fit the batch.
local function geometry_fits(span,width,length,direction)
    local norm=direction[1]^2+direction[2]^2+direction[3]^2
    return not (span<=0.1 or span>3.5 or width<=0 or width>1 or length<0.05 or length>2
        or math.abs(norm-1)>0.001 or math.abs(direction[3])>0.001)
end

-- Native forward/up basis must remain horizontal and orthonormal. Ignore
-- its translation, which each query below replaces explicitly.
local function basis_matches(matrix,direction)
    if type(matrix)~='string' or #matrix~=64 then return false end
    local expected={direction[2],-direction[1],0,0,direction[1],direction[2],0,0,0,0,1,0}
    for i,want in ipairs(expected) do
        local actual=number(matrix,(i-1)*4)
        if not finite(actual) or math.abs(actual-want)>0.001 then return false end
    end
    return true
end

-- The first and last source positions: half a slice in from each endpoint,
-- lowered by the box's vertical half-extent.
local function endpoints(first,last,direction,depth)
    local near,far={},{}
    for axis=1,3 do
        local shift=axis==3 and -f32(0.05) or 0
        near[axis]=f32(f32(f32(depth*direction[axis])+first[axis])+shift)
        far[axis]=f32(f32(last[axis]-f32(depth*direction[axis]))+shift)
    end
    return near,far
end

-- One slot's private descriptor: the retained record with the native basis,
-- the interpolated source and target, and the slice box.
local function reprojected_record(hit,matrix,near,far,span,width,depth)
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
    return ffi.string(record,128)
end

function M.reproject(s,fresh)
    local first,last,direction,span,width,length=fresh_geometry(s,fresh)
    if not first or not geometry_fits(span,width,length,direction) or not s.native.query_basis then
        return nil,'unsupported_fresh_approach'
    end
    local matrix=s.native.query_basis(direction)
    if not basis_matches(matrix,direction) then return nil,'unsupported_query_basis' end
    local depth=f32(f32(length/10)*0.5)
    local near,far=endpoints(first,last,direction,depth)
    local records={}
    for i,hit in ipairs(s.hits) do
        if hit.slot~=i-1 or #hit.record~=128 then return nil,'unsupported_fresh_approach' end
        records[i]=reprojected_record(hit,matrix,near,far,span,width,depth)
    end
    for i,record in ipairs(records) do s.hits[i].record=record end
    s.controller_bytes=fresh;s.reprojected=true
    return true
end

-- Rebuilt queries: no shared descriptor survives, so neither an old hit count
-- nor old geometry may authorize a cast, including the raised-top fallback.
-- True, else nil, why and the native approach reason.
local function rebuilt_context(s,state,matched,why,fresh)
    if not fresh or (not matched and why~='native_approach_geometry_changed') then
        return nil,'fresh_approach_unavailable',why
    end
    matched,why=M.reproject(s,fresh)
    if not matched then return nil,why or 'native_approach_changed_or_blocked' end
    state.query_rebuilds=(state.query_rebuilds or 0)+1
    state.context_reprojections=(state.context_reprojections or 0)+1
    return true
end

-- The native approach context of a refresh: true when the retained (or
-- reprojected) geometry may be cast, else nil, why and, for rebuilt queries,
-- the native approach reason.
local function approach_context(s,state)
    local matched,why,fresh,code=s.native.context_matches(s.controller_bytes)
    state.last_approach_reason=why or (matched and 'matched' or 'unknown')
    state.last_approach_code=code
    if s.rebuild_queries then return rebuilt_context(s,state,matched,why,fresh) end
    if not matched and why=='native_approach_geometry_changed' and fresh then
        matched,why=M.reproject(s,fresh)
        if matched then state.context_reprojections=(state.context_reprojections or 0)+1 end
    end
    if not matched then return nil,why or 'native_approach_changed_or_blocked' end
    return true
end

-- True when a query's source and target stay near and in front of the
-- native mover (1.5 units horizontally, 5 vertically).
local function cast_in_reach(s,record)
    for _,offset in ipairs({64,92}) do
        local v=vector(record,offset)
        local dx,dy=v[1]-s.root[1],v[2]-s.root[2]
        if dx*dx+dy*dy>2.25 or math.abs(v[3]-s.root[3])>5
            or dx*s.direction[1]+dy*s.direction[2]<-0.15 then
            return false
        end
    end
    return true
end

-- Casts a slot's query again into private storage; the hit takes the result.
local function recast(s,state,hit)
    local bytes,count=s.native.refresh_query(hit.record,s.world)
    assert(type(bytes)=='string' and #bytes==44 and (count==0 or count==1),'Invalid refreshed query')
    state.fresh_queries=(state.fresh_queries or 0)+1
    hit.bytes,hit.count=bytes,count
    hit.position,hit.normal_z=vector(bytes,0),number(bytes,20)
    hit.unit,hit.actor=u32(bytes,28),u32(bytes,32)
end

function M.refresh(s,state)
    local ready,why,approach=approach_context(s,state)
    if not ready then return nil,why,approach end
    local originals={}
    for i,hit in ipairs(s.hits) do
        originals[i]=hit.bytes
        if s.rebuild_queries or hit.count==1 then
            -- Retained geometry must remain near and in front of this avatar.
            -- A fresh cast prevents old hits from surviving removed obstacles.
            if not cast_in_reach(s,hit.record) then return nil,'retained_query_out_of_reach' end
            recast(s,state,hit)
        end
    end
    return originals
end

-- True when a hit lies beyond the 1.5-unit horizontal reach or behind the
-- avatar's direction.
local function out_of_reach(s,hit)
    local dx,dy=hit.position[1]-s.root[1],hit.position[2]-s.root[2]
    return dx*dx+dy*dy>2.25 or dx*s.direction[1]+dy*s.direction[2]<-0.15
end

-- True while every snapshot guard still holds its bytes.
local function guards_hold(api,s)
    for _,g in ipairs(s.guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return false end
    end
    return true
end

-- Read-only, fresh native probes decide whether an input window needs any
-- assistance. Ordinary candidates take priority. Nothing is slowed or changed
-- merely because Space was pressed, or because old retained hits look usable.

-- The candidate search's snapshot of a consumed query for the avatar the
-- slope check verified, else nil and why. Match the main query path's
-- handling of transient unavailable snapshots. Native validation errors after
-- a snapshot still reach loader cleanup.
local function candidate_snapshot(api,game,exe,state,owner)
    local ok,s,why=pcall(M.snapshot,api,game,exe,nil,true)
    if not ok then state.candidate_error=tostring(s);return nil,'candidate_snapshot_unavailable' end
    if not s or s.stage~=3 then return nil,why or 'waiting_for_consumed_query' end
    if api.distance(s.entity,owner.entity)~=0 then return nil,'candidate_identity_changed' end
    return s
end

-- True when a grounded avatar at the default climb height may replace a
-- blocked, changed, out-of-reach or missing ordinary approach with the
-- independent raised search.
local function raised_wanted(s,originals,reason,approach_reason)
    if originals or not s.ground or not (math.abs(s.max_height-1.95)<0.001) or not s.native.raised_approach then
        return false
    end
    return reason=='native_approach_blocked' or reason=='native_approach_geometry_changed'
        or reason=='retained_query_out_of_reach'
        or reason=='fresh_approach_unavailable' and approach_reason=='native_approach_blocked'
end

-- The raised search's fresh approach, reprojected into the private queries,
-- else nil and why.
local function raised_context(s,state)
    local fresh,why=s.native.raised_approach(s.controller_bytes,s.unit,s.mover_name,s.direction,s.ground_reach)
    if not fresh then return nil,why or 'raised_approach_unavailable' end
    local ready;ready,why=M.reproject(s,fresh)
    if not ready then return nil,why end
    state.raised_approach_rebuilds=(state.raised_approach_rebuilds or 0)+1
    return fresh
end

-- A higher-top discovery cast does not consume retained hits. Requiring
-- the original low-height approach to succeed first makes that discovery
-- circular. Only this private, bounded search may continue on a context
-- rejection; ordinary/slope retries require matched or freshly rebuilt geometry.
local function context_usable(originals,reason,raised_fresh)
    return originals or reason=='native_approach_blocked' or reason=='native_approach_geometry_changed'
        or reason=='native_approach_changed_or_blocked' or raised_fresh
end

-- The diagnostics trace of one candidate search.
local function new_trace(api,s,originals,reason)
    return {time=api.time(),root=s.root,direction=s.direction,ground=s.ground,
        context=originals and (s.reprojected and 'reprojected' or 'matched') or reason,
        passes={ordinary={},slope={},raised={}}}
end

-- The steep-slope selection, or nil and 'ordinary_candidate_retained' while
-- an ordinary candidate exists.
local function slope_pass(s,trace)
    local _,ordinary=M.plan(s,trace.passes.ordinary)
    if ordinary then return nil,'ordinary_candidate_retained' end
    s.normal_threshold=f32(math.cos(f32(65*f32(math.pi/180))))
    local _,selected=M.plan(s,trace.passes.slope)
    return selected
end

-- True when a downward cast's start and target stay near and in front of the
-- native mover and the start lies above the target.
local function raised_in_reach(s,start,target)
    local dx,dy=start[1]-s.root[1],start[2]-s.root[2]
    local tx,ty=target[1]-s.root[1],target[2]-s.root[2]
    return not (dx*dx+dy*dy>2.25 or tx*tx+ty*ty>2.25 or start[3]<target[3]
        or math.abs(start[3]-s.root[3])>5 or math.abs(target[3]-s.root[3])>5
        or dx*s.direction[1]+dy*s.direction[2]<-0.15
        or tx*s.direction[1]+ty*s.direction[2]<-0.15)
end

-- The room a query box needs above a top at the allowed surface angle: its
-- vertical extent plus its horizontal footprint's rise, else nil.
local function probe_clearance(record,baseline)
    local size=vector(record,80)
    for _,dimension in ipairs(size) do
        if dimension<=0 or dimension>0.5 then return nil end
    end
    local extent=math.abs(number(record,24))*size[1]
        +math.abs(number(record,40))*size[2]+math.abs(number(record,56))*size[3]
    local horizontal=0
    for axis=0,2 do
        local x,y=number(record,16+axis*16),number(record,20+axis*16)
        horizontal=horizontal+math.sqrt(x*x+y*y)*size[axis+1]
    end
    if not finite(extent) or extent<=0 or extent>0.25
        or not finite(horizontal) or horizontal<=0 or horizontal>0.5
        or baseline<0.7 or baseline>1 then return nil end
    return extent+horizontal*math.sqrt(math.max(0,1-baseline*baseline))/baseline+0.01
end

-- Raise only the start of a private downward cast; leave its end, shape,
-- filter, ignored unit and returned normals untouched. Anchor the discovery
-- ceiling to the current native mover, not the potentially clipped/low
-- retained approach ceiling, and reserve space for the full box over a top at
-- the allowed surface angle. True, else nil and why.
local function raise_hit(s,state,hit,baseline)
    local start,target=vector(hit.record,64),vector(hit.record,92)
    if not raised_in_reach(s,start,target) then return nil,'raised_query_out_of_reach' end
    local clearance=probe_clearance(hit.record,baseline)
    if not clearance then return nil,'unsupported_probe_extent' end
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
    return true
end

-- The higher-top selection: every slot cast again from above the 2.5-unit
-- allowance, at the original surface angle. Nil and why when a slot cannot be.
local function ledge_pass(s,state,trace,baseline)
    s.normal_threshold=baseline;s.max_height=2.5;s.min_height=0.5
    for _,hit in ipairs(s.hits) do
        local raised,why=raise_hit(s,state,hit,baseline)
        if not raised then return nil,why end
    end
    local _,selected=M.plan(s,trace.passes.raised)
    state.raised_trace=trace
    return selected
end

-- The assisted candidate: kind ('slope' or 'ledge') and selection, or nil, nil
-- and why when a pass gives up. The ledge pass runs for a grounded avatar at
-- the default climb height when no steep candidate was selected.
local function assisted_selection(s,state,trace,originals)
    local baseline=s.normal_threshold
    local selected,why
    if originals then
        selected,why=slope_pass(s,trace)
        if why then return nil,nil,why end
    end
    if selected or not s.ground or not (math.abs(s.max_height-1.95)<0.001) then return 'slope',selected end
    selected,why=ledge_pass(s,state,trace,baseline)
    if why then return nil,nil,why end
    if not originals then state.raised_context_fallbacks=(state.raised_context_fallbacks or 0)+1 end
    return 'ledge',selected
end

-- True when the raised search, repeated, returns the same context within
-- 0.02 units.
local function raised_unchanged(s,raised_fresh)
    local fresh=s.native.raised_approach(s.controller_bytes,s.unit,s.mover_name,s.direction,s.ground_reach)
    if type(fresh)~='string' or #fresh~=0x2b0 or u32(fresh,4)~=1
        or u32(fresh,684)~=u32(raised_fresh,684) then return false end
    for offset=488,528,4 do
        local v=number(fresh,offset)
        if not finite(v) or math.abs(v-number(raised_fresh,offset))>0.02 then return false end
    end
    return true
end

-- Why the candidate may not be granted (its approach context or a guard
-- changed), else nil.
local function commit_blocked(api,s,raised_fresh)
    if raised_fresh then
        if not raised_unchanged(s,raised_fresh) then return 'raised_context_changed_before_commit' end
    elseif s.reprojected and not s.native.context_matches(s.controller_bytes) then
        return 'native_context_changed_before_commit'
    end
    if not guards_hold(api,s) then return 'candidate_changed' end
    return nil
end

local function assist_candidate(api,game,exe,state,owner)
    local s,why=candidate_snapshot(api,game,exe,state,owner)
    if not s then return nil,why end
    local originals,reason,approach_reason=M.refresh(s,state)
    local raised_fresh
    if raised_wanted(s,originals,reason,approach_reason) then
        raised_fresh,why=raised_context(s,state)
        if not raised_fresh then return nil,why end
        reason='fresh_raised_approach'
    end
    if not context_usable(originals,reason,raised_fresh) then return nil,reason end
    local trace=new_trace(api,s,originals,reason)
    state.candidate_trace=trace
    local kind,selected
    kind,selected,why=assisted_selection(s,state,trace,originals)
    if why then return nil,why end
    if not selected then return nil,'no_usable_assisted_candidate' end
    local hit=s.hits[selected.slot+1]
    if out_of_reach(s,hit) then return nil,'candidate_out_of_reach' end
    why=commit_blocked(api,s,raised_fresh)
    if why then return nil,why end
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

-- The writes of a late retry: the chosen fresh hit (its actor cleared for a
-- metadata fallback), every other originally nonempty slot's unit cleared, and
-- the phase back to 2.
local function retry_writes(s,originals,selected)
    local chosen=s.hits[selected.slot+1]
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
    return writes
end

-- Restores the retry's writes and gives up with reason.
local function rollback(api,state,pending,reason)
    local restored=M.restore(api,pending)
    state.pending=nil
    return false,restored and reason or 'query_restore_failed',false
end

local function count_retry(state,s,selected)
    state.prepared=(state.prepared or 0)+1
    if selected.metadata then state.metadata_fallbacks=(state.metadata_fallbacks or 0)+1 end
    state.retry_calls=(state.retry_calls or 0)+1
    if s.reprojected then state.reprojected_retries=(state.reprojected_retries or 0)+1 end
    if s.prior_step_report then state.step_report_retries=(state.step_report_retries or 0)+1 end
end

local function count_start(state,s,started)
    if not started then return end
    state.native_starts=(state.native_starts or 0)+1
    if s.reprojected then state.reprojected_starts=(state.reprojected_starts or 0)+1 end
    if s.prior_step_report then state.step_report_starts=(state.step_report_starts or 0)+1 end
end

-- True when the native driver entered climbing (same epoch, climbing flag).
local function native_started(api,s)
    if not M.same_epoch(api,s) then return false end
    local flags=api.read(s.flags_address,24)
    return flags and bit.band(u32(flags,12),0x200)~=0 or false
end

-- Exposes the fresh result, runs the original driver with zero dt and restores.
local function retry_commit(api,s,state,writes,selected)
    local pending={snapshot=s,writes={}}
    state.pending=pending
    local failure=commit(api,s,pending,writes)
    if failure=='changed' then
        local restored=M.restore(api,pending);state.pending=nil
        return restored,restored and 'query_changed_before_commit' or 'query_restore_failed',false
    end
    if failure then return rollback(api,state,pending,failure=='write' and 'query_write_failed' or 'query_restore_failed') end
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes then
        return rollback(api,state,pending,'query_changed_before_retry')
    end
    count_retry(state,s,selected)
    local called,reason=pcall(s.native.retry,s.controller)
    if not called then return rollback(api,state,pending,'native_retry_failed: '..tostring(reason)) end
    local started=native_started(api,s)
    local restored=M.restore(api,pending);state.pending=nil
    if not restored then return false,'query_restore_failed',false end
    count_start(state,s,started)
    return true,started and 'native_local_vault_started' or 'native_local_retry_rejected',started
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
    if out_of_reach(s,s.hits[selected.slot+1]) then return true,'retained_query_out_of_reach',false end
    local writes=retry_writes(s,originals,selected)
    if s.reprojected and not s.native.context_matches(s.controller_bytes) then
        return true,'native_context_changed_before_commit',false
    end
    if not guards_hold(api,s) then return true,'query_changed_before_commit',false end
    return retry_commit(api,s,state,writes,selected)
end

-- The previous check's prepared writes while their epoch is unchanged, else
-- nil. A changed epoch (consumed or reused batch) drops them unwritten, as
-- M.restore does.
local function held_writes(api,state)
    local pending=state.pending
    if not pending then return nil end
    if not M.same_epoch(api,pending.snapshot) then state.pending=nil;return nil end
    return pending
end

-- Restores the held writes that are still in place, as M.restore does once the
-- epoch is confirmed (held_writes, this check).
local function release(api,state,held)
    if not restore_in_place(api,held) then return false end
    state.pending=nil
    return true
end

-- True when this check would prepare exactly the held writes from unchanged
-- data: they stay in place, with no restore, no new write and no protection
-- query. The snapshot of this check has just read every guard (its epoch
-- among them) and nothing was written since, so they are not read a second
-- time: keeping writes nothing, and the next check reads them all again. The
-- held writes and the input are read again, as before a commit.
local function keeps(api,s,held,writes)
    if #writes~=#held.writes then return false end
    for i,w in ipairs(writes) do
        local h=held.writes[i]
        if w.address~=h.address or w.before~=h.before or w.after~=h.after then return false end
    end
    for _,w in ipairs(held.writes) do
        if api.read(w.address,#w.after)~=w.after then return false end
    end
    return api.read(s.input_address,1)==s.manual_bytes
end

-- Idle gate: the slope check of this poll has just resolved and verified the
-- local avatar, so its controller's phase word (one read, at the address the
-- slope snapshot hands over) and the input that check read decide whether a
-- vault check can act at all. The word is read into one reused cell, without
-- allocating. Stages are counted as the full snapshot counts them; anything
-- else goes on to the full snapshot.
local phase_word=ffi.new('uint32_t[1]')
local function vault_idle(api,state,avatar)
    if not api.read_into(avatar.vault_phase,4,phase_word) then return nil end
    local stage=phase_word[0]
    local idle=stage~=2 and stage~=3 and 'waiting_for_vault_query' or not avatar.manual and 'waiting_for_manual_vault'
    if idle then count_stage(state,stage) end
    return idle
end

local function prepared(state,pending,selected)
    state.pending=pending
    state.prepared=(state.prepared or 0)+1
    if selected.metadata then state.metadata_fallbacks=(state.metadata_fallbacks or 0)+1 end
    state.last_slot=selected.slot
    return true,selected.metadata and 'local_manual_metadata_fallback_prepared' or 'local_manual_alternative_prepared',true
end

-- Commits a new stage-2 plan: guards verified, one batch, epoch and input
-- verified again after it.
local function prepare(api,s,state,writes,selected)
    if not guards_hold(api,s) then return true,'query_changed_before_commit',false end
    -- A failed API may write partially: the rollback covers every attempted write.
    local pending={snapshot=s,writes={}}
    local failure=commit(api,s,pending,writes)
    if failure then
        local restored=M.restore(api,pending)
        if failure=='changed' then return restored,restored and 'query_changed_before_commit' or 'query_restore_failed',false end
        return false,restored and failure=='write' and 'query_write_failed' or 'query_restore_failed',false
    end
    if not M.same_epoch(api,s) or api.read(s.input_address,1)~=s.manual_bytes then
        local restored=M.restore(api,pending)
        return restored,restored and 'query_changed_after_commit' or 'query_restore_failed',false
    end
    return prepared(state,pending,selected)
end

-- Stage 2: keep the held writes when the plan is unchanged, else restore them
-- and prepare the new plan.
local function plan_batch(api,s,state,held)
    local planned,writes,selected=pcall(M.plan,s)
    if held then
        if planned and keeps(api,s,held,writes) then return prepared(state,{snapshot=s,writes=held.writes},selected) end
        if not release(api,state,held) then return false,'query_restore_failed',false end
    end
    if not planned then return false,'validation_failed: '..tostring(writes),false end
    if #writes==0 then return true,'native_vault_checks_retained',true end
    return prepare(api,s,state,writes,selected)
end

-- Stage 3: the retained batch, through a late native retry.
local function retry(api,s,state)
    local called,accepted,why,active=pcall(M.retry_consumed,api,s,state)
    if not called then
        local restored=M.restore(api,state.pending);state.pending=nil
        return false,restored and 'validation_failed: '..tostring(accepted) or 'query_restore_failed',false
    end
    state.last_retry_reason=why
    return accepted,why,active
end

-- One check after the snapshot (ok, s, reason as pcall returned them).
local function vault_check(api,state,held,ok,s,reason)
    -- Without a new stage-2 plan there is nothing to keep: restore first, as
    -- every check did before it read the batch.
    if held and not (ok and s and s.stage==2) then
        if not release(api,state,held) then return false,'query_restore_failed',false end
        held=nil
    end
    if not ok then return true,'waiting_for_game_data: '..tostring(s),false end
    if not s then return true,reason,false end
    state.observed_queries=(state.observed_queries or 0)+1
    if s.stage==3 then return retry(api,s,state) end
    return plan_batch(api,s,state,held)
end

local function apply(api,game,exe,state)
    local held=held_writes(api,state)
    if M.assistance then
        local accepted,reason=M.assistance.step(api,game,exe,state)
        if not accepted then return false,reason,false end
    end
    local avatar=state.avatar;state.avatar=nil
    -- The slope check of this poll found no mission (false): its mission gate
    -- reads would answer the same. Held writes still go through the snapshot,
    -- whose failure restores them.
    if avatar==false and not held then return true,'waiting_for_mission',false end
    local idle=avatar and not held and vault_idle(api,state,avatar)
    if idle then return true,idle,false end
    return vault_check(api,state,held,pcall(M.snapshot,api,game,exe,state,nil,held,avatar and avatar.identity and avatar))
end

-- One check. state.busy tells the loader whether a check after the game's
-- update is needed: query writes held, a slope assist or its press window, or
-- a vault check past its idle gates (a query and the input both present).
function M.apply(api,game,exe,state)
    local observed=state.observed_queries
    local accepted,reason,active=apply(api,game,exe,state)
    state.busy=state.observed_queries~=observed or state.pending~=nil or state.slope_lease~=nil
        or state.assist_intent~=nil
    return accepted,reason,active
end

function M.stop(api,game,exe,state)
    local queries=M.restore(api,state.pending)
    if queries then state.pending=nil end
    local slopes=not M.assistance or M.assistance.stop(api,game,exe,state)
    return queries and slopes
end

-- Machine code: the checks of every frame stay compiled: the idle gate, the
-- snapshot, plan and keep of a held vault query. Retries, commits, restores and
-- candidate searches run at most a few times per vault; compiled they only took
-- more of the LuaJIT code cache that the game and every mod share, with no
-- measurable gain in the game's lua51.dll, so they stay interpreted. Nothing is
-- flushed.
if jit and jit.off then
    for _,fn in ipairs({fresh_geometry,geometry_fits,basis_matches,endpoints,reprojected_record,M.reproject,
        rebuilt_context,approach_context,cast_in_reach,recast,M.refresh,candidate_snapshot,raised_wanted,raised_context,
        context_usable,new_trace,slope_pass,raised_in_reach,probe_clearance,raise_hit,ledge_pass,assisted_selection,
        raised_unchanged,commit_blocked,assist_candidate,M.assist_candidate,write_controller,first_mismatch,
        restore_in_place,M.restore,undo_partial,commit,out_of_reach,retry_writes,guards_hold,rollback,count_retry,
        count_start,native_started,retry_commit,M.retry_consumed,release,prepare,prepared,retry,M.stop}) do
        jit.off(fn)
    end
end
return M
