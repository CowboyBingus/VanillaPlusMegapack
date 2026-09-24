local ffi,bit=require('ffi'),require('bit')
local A={limit=65,radius=3}
local INVALID=0xffffffff
local function value(b,o,t)
    local v=ffi.new(t..'[1]');ffi.copy(v,b:sub(o+1),ffi.sizeof(v));return tonumber(v[0])
end
local function u(b,o)return value(b,o or 0,'uint32_t') end
local function f(b,o)return value(b,o or 0,'float') end
local function bytes(v)return ffi.string(ffi.new('float[1]',v),4) end
local function finite(v)return v==v and math.abs(v)<100000 end
local function vec(b,o)return {f(b,o),f(b,o+4),f(b,o+8)} end
local COS=math.cos(A.limit*math.pi/180)

-- A saved identity is used only for cleanup. It can locate the original avatar
-- after registry compaction or a local-player switch, never grant a new lease.
function A.snapshot(api,game,exe,key)
    local s={guards={}}
    local function read(a,n,guard)
        local b=assert(api.read(a,n),'Slope data unavailable');assert(#b==n,'Short slope read')
        if guard then s.guards[#s.guards+1]={address=a,bytes=b} end
        return b
    end
    local function ptr(b,o)return assert(api.pointer(b,o),'Slope pointer unavailable') end
    local function global(rva)return ptr(read(game+rva,8,true)) end
    local function lookup(a,id,limit)
        local h=read(a,20,true)
        local cap,empty,mult=u(h,8),u(h,12),u(h,16)
        assert(cap>0 and cap<=limit and bit.band(cap,cap-1)==0,'Unsupported slope map')
        local data=ptr(h)
        for i=0,math.min(cap,128)-1 do
            local product=ffi.new('uint64_t',id)*ffi.new('uint64_t',mult)
            local slot=bit.band(tonumber(ffi.cast('uint32_t',product))+i,cap-1)
            local row=read(data+slot*8,8,true)
            if u(row)==id then return u(row,4) end
            if u(row)==empty then return nil end
        end
    end
    local ref
    if key then ref=key.ref else
        local mode=read(global(0x33266a0),0x44,true)
        if u(mode,8)==0 or u(mode,0x40)<1 or u(mode,0x40)>7 then return nil,'outside_mission' end
        local pm=global(0x3326468)
        local counts=read(pm+0x84,8)
        assert(u(counts)<=4 and u(counts,4)<=4,'Unsupported player count')
        if u(counts)==0 or u(counts,4)==0 then return nil,'no_local_avatar' end
        if bit.band(read(ptr(read(pm+0xe8,8,true)),24,true):byte(21),1)==0 then return nil,'no_local_avatar' end
        ref=u(read(pm+0x3a8,4,true))
    end
    if ref==0x7fff then return nil,'gone' end
    local owner,manager=global(0x346bf98),global(0x3326d20)
    if key and (api.distance(owner,key.owner)~=0 or api.distance(manager,key.manager)~=0) then return nil,'gone' end
    local ei=lookup(owner+0xf22ec8,ref,1048576)
    if not ei or ei==INVALID then return nil,'gone' end
    assert(ei<262144,'Unsupported entity index')
    s.entity=owner+0xf32f18+ei*24
    local entity=read(s.entity,24,true)
    if entity:sub(1,8)~='\151\250\077\041\077\051\028\077' then return nil,'gone' end
    local id,unit=u(entity,8),u(entity,12)
    if key and (key.id~=id or key.unit~=unit) then return nil,'gone' end
    if not key and bit.band(entity:byte(21),1)==0 then return nil,'no_local_avatar' end
    local ai=lookup(manager+0xf8,id,64)
    if not ai or ai==INVALID then return nil,'gone' end
    assert(ai<u(read(manager+0x6c,4)) and ai<8,'Unsupported avatar index')
    assert(read(ptr(read(manager+0x110+ai*8,8,true)),24,true)==entity,'Avatar registry mismatch')
    assert(u(read(manager+0x53e1b8+ai*0x1238+0x2ac,4,true))==id,'Vault identity mismatch')
    local direction=manager+0x53e134+ai*0x1238
    assert(u(read(direction+40,4,true))==id,'Movement direction identity mismatch')
    local mm=global(0x3326558)
    local mi=lookup(mm+0x48a0,id,1048576)
    assert(mi and mi~=INVALID and mi<8192,'Movement unavailable')
    local move=read(ptr(read(mm+0x48c8,8,true))+mi*132,132)
    local mover_address=ptr(read(mm+0x48d0,8,true))+mi*164
    local mover=read(mover_address,164)
    read(mover_address+76,16,true)
    local handle=u(mover,88)
    local pool=ptr(read(exe+0x27c3298+bit.rshift(handle,30)*0x810,8,true))
    local h=read(pool,56,true)
    local index=bit.band(handle,u(h,40))
    assert(index>=0 and index<u(h,36) and bit.band(handle,u(h,52))~=0,'Invalid mover handle')
    local layout=u(h,28)
    local start=ptr(h)+index*bit.band(layout,65535)
    assert(u(read(start+bit.band(bit.rshift(layout,16),255),4,true))==handle,'Reused mover handle')
    local record=read(start+bit.rshift(layout,24),32,true)
    assert(u(record,8)==unit,'Mover belongs to another unit')
    local definition,object=ptr(record,16),ptr(record,24)
    local def=read(definition,28,true)
    assert(u(def)==u(mover,76),'Mover name mismatch')
    assert(api.distance(ptr(read(object,8,true)),exe+0x16a16d8)==0,'Unsupported character controller')
    local up=vec(read(object+80,12,true),0)
    assert(math.abs(up[1])+math.abs(up[2])+math.abs(up[3]-1)<0.001,'Unsupported up vector')
    -- Preserve the separate 70-degree support/drop limit and shared definition.
    assert(math.abs(f(def,20)-50*math.pi/180)<0.001 and math.abs(f(def,24)-70*math.pi/180)<0.001,
        'Unsupported mover definition')
    assert(math.abs(f(read(object+100,4,true))-math.cos(70*math.pi/180))<0.001,'Unsupported support filter')
    s.key={ref=ref,id=id,unit=unit,owner=owner,manager=manager}
    s.manager=manager;s.handle=handle;s.object=object;s.mover_name=u(mover,76)
    s.cells={cap=direction+8,slope=object+96}
    local oi=lookup(manager+0x547c70,id,64)
    local settings
    if oi and oi~=INVALID then
        assert(oi<8,'Unsupported avatar override')
        local base=manager+0x547d24+oi*852
        settings=read(base,852)
        s.cells.enter=base+152;s.cells.exit=base+172;s.cells.height=base+260
    else
        local component=ptr(read(owner+0xf12bb8,8,true))
        local map=read(component,32,true);local found=false
        for i=0,1 do
            if map:sub(i*16+1,i*16+8)==entity:sub(1,8) and u(map,i*16+8)==0 then found=true end
        end
        assert(found,'Unsupported avatar resource map')
        settings=read(component+32,852)
    end
    -- Native allocation has a fixed eight-record capacity in this build.
    s.override_count=u(read(manager+0x547d20,4,true))
    assert(s.override_count<=8,'Unsupported override count')
    s.walk=f(settings,12);s.enter=f(settings,152);s.exit=f(settings,172);s.ground_max=f(settings,260)
    assert(finite(s.walk) and s.walk>0 and s.walk<=10,'Unsupported walking speed')
    s.values={cap=read(s.cells.cap,4),slope=read(s.cells.slope,4)}
    if s.cells.enter then
        s.values.enter=read(s.cells.enter,4);s.values.exit=read(s.cells.exit,4);s.values.height=read(s.cells.height,4)
    end
    if key then return s end
    s.manual=read(manager+0x150+ai*0xa7aec+0x1b68+14*32,1,true):byte()~=0
    local flags=read(manager+0x53e880+ai*0x1238,24,true)
    s.climbing=bit.band(u(flags,12),0x200)~=0
    s.eligible=bit.band(u(flags),2)~=0 and bit.band(u(flags),0x404000)==0
        and bit.band(u(flags,4),0x8000000)==0 and bit.band(u(flags,8),0x20084000)==0
        and bit.band(u(flags,12),0x5181c)==0 and bit.band(u(flags,16),9)==0
    s.ground=bit.band(u(flags,8),4)==0 and bit.band(u(flags,12),0x26)==0
        and move:byte(16)==0 and move:byte(13)==0
    local n=vec(move,20);local length=math.sqrt(n[1]^2+n[2]^2+n[3]^2)
    s.normal_z=finite(length) and length>0.99 and length<1.01 and n[3]/length or -1
    s.native=assert(api.native(game,exe),'Native slope support unavailable')
    s.root=s.native.mover_position(unit,s.mover_name)
    assert(s.root and finite(s.root[1]) and finite(s.root[2]) and finite(s.root[3]),'Invalid mover position')
    return s
end

local function guarded(api,s)
    for _,g in ipairs(s.guards) do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
local function same(api,a,b)
    return a.id==b.id and a.unit==b.unit and a.ref==b.ref
        and api.distance(a.manager,b.manager)==0 and api.distance(a.owner,b.owner)==0
end

function A.stop(api,game,exe,state)
    local lease=state.slope_lease
    if not lease then return true end
    local ok,s,why=pcall(A.snapshot,api,game,exe,lease.key)
    if not ok then return false end
    if not s then
        if why=='gone' then state.slope_lease=nil;return true end
        return false
    end
    if not guarded(api,s) then return false end
    local restored=true
    for i=#lease.writes,1,-1 do
        local w=lease.writes[i];local address=s.cells[w.name]
        -- A replacement mover has its own defaults; never restore into it.
        if w.name=='slope' and (lease.handle~=s.handle or api.distance(lease.object,s.object)~=0) then address=nil end
        if address then
            local current=api.read(address,4)
            local owned=current==w.after
            if w.partial and current and not owned and current~=w.before then
                owned=true
                for j=1,4 do
                    if current:byte(j)~=w.before:byte(j) and current:byte(j)~=w.after:byte(j) then owned=false end
                end
            end
            if current==nil then restored=false
            elseif owned then
                if not guarded(api,s) or not api.writable_data(address,4)
                    or not api.write(address,w.before) or api.read(address,4)~=w.before then restored=false end
            end
        end
    end
    if restored then state.slope_lease=nil end
    return restored
end

-- Decisions use actual native climbing and ground contact, not query readiness.
-- Stable steep support has no timer that would unexpectedly drop a stationary
-- player. It remains walking-only inside the original three-metre area.
function A.keep(lease,s,now)
    if not s.eligible then return false,'ineligible' end
    local dx,dy,dz=s.root[1]-lease.anchor[1],s.root[2]-lease.anchor[2],s.root[3]-lease.anchor[3]
    if dx*dx+dy*dy>A.radius^2 or math.abs(dz)>3 then return false,'left_area' end
    if s.climbing then
        if now>lease.started+8 then return false,'climb_timeout' end
        lease.phase='climb';lease.last_climb=now;return true
    end
    if lease.phase=='attempt' then return now<=lease.started+1.25,'attempt_timeout' end
    if lease.kind=='ledge' then return false,'ledge_climb_finished' end
    if s.ground and s.normal_z>=COS then
        lease.air_since=nil
        if s.normal_z<math.cos(44*math.pi/180) then
            lease.phase='support';lease.flat_since=nil;return true
        end
        lease.flat_since=lease.flat_since or now
        return now-lease.flat_since<0.35,'flat_ground'
    end
    lease.air_since=lease.air_since or now
    return now-lease.air_since<0.25,'unsupported'
end

function A.step(api,game,exe,state)
    local function finish(reason)
        state.slope_status=reason
        state.assist_intent=nil
        if state.slope_lease then state.slope_last_release=reason end
        if state.slope_lease and state.slope_lease.kind=='ledge' and reason=='attempt_timeout' then
            state.ledge_attempt_expiries=(state.ledge_attempt_expiries or 0)+1
        end
        if not A.stop(api,game,exe,state) then return false,'slope_restore_failed' end
        return true
    end
    local ok,s=pcall(A.snapshot,api,game,exe)
    if not ok or not s then
        -- Require a fresh input release after transitions or unavailable data.
        state.slope_down=true
        return finish(ok and 'waiting_for_avatar' or 'waiting_for_slope_data')
    end
    local rising=s.manual and state.slope_down==false
    state.slope_down=s.manual
    local now=api.time()
    local lease=state.slope_lease
    if lease then
        if not same(api,lease.key,s.key) or lease.handle~=s.handle or api.distance(lease.object,s.object)~=0 then
            return finish('identity_changed')
        end
        for _,w in ipairs(lease.writes) do
            if s.values[w.name]~=w.after then return finish('settings_changed') end
        end
        local previous=lease.phase
        local keep,why=A.keep(lease,s,now)
        if not keep then return finish(why) end
        if lease.kind=='slope' and lease.phase~='attempt' and not lease.speed_capped then
            -- No movement cap during detection or a rejected attempt. Apply it
            -- only after this assisted attempt actually enters native climbing.
            local cap=f(s.values.cap)
            if not finite(cap) or not guarded(api,s) then return finish('speed_cap_unavailable') end
            local w={name='cap',before=s.values.cap,after=bytes(cap>=0 and math.min(cap,s.walk) or s.walk),partial=true}
            lease.writes[#lease.writes+1]=w
            if not api.writable_data(s.cells.cap,4) or not api.write(s.cells.cap,w.after)
                or api.read(s.cells.cap,4)~=w.after then
                local restored=A.stop(api,game,exe,state)
                return false,restored and 'speed_cap_write_failed' or 'slope_restore_failed'
            end
            w.partial=false;lease.speed_capped=true
        end
        if lease.phase=='climb' and previous~='climb' then
            state.slope_climbs=(state.slope_climbs or 0)+1
            if lease.kind=='ledge' then state.ledge_climbs=(state.ledge_climbs or 0)+1 end
        end
        if lease.phase=='support' and previous~='support' then state.slope_landings=(state.slope_landings or 0)+1 end
        state.slope_status=lease.phase;return true
    end
    state.slope_status='waiting_for_manual_climb'
    if rising then state.assist_intent={key=s.key,deadline=now+1.25} end
    if not s.manual or not s.eligible or s.climbing then state.assist_intent=nil;return true end
    local intent=state.assist_intent
    if not intent or now>intent.deadline or not same(api,intent.key,s.key) then state.assist_intent=nil;return true end
    if intent.checked and now-intent.checked<0.1 then return true end
    intent.checked=now
    if s.enter~=45 or s.exit~=40 or math.abs(f(s.values.slope)-math.cos(50*math.pi/180))>0.001 then
        state.slope_status='custom_slope_settings_retained';return true
    end
    if not guarded(api,s) then return true end
    state.candidate_checks=(state.candidate_checks or 0)+1
    local kind,reason
    if A.candidate then kind,reason=A.candidate(api,game,exe,state,s) end
    state.candidate_reason=reason or 'candidate_validator_unavailable'
    if kind~='slope' and kind~='ledge' then return true end
    if kind=='ledge' and (not s.ground or math.abs(s.ground_max-1.95)>0.001) then return true end
    if not guarded(api,s) then return true end
    if not s.cells.enter then
        if s.override_count>=8 then state.slope_status='override_capacity_reached';return true end
        -- Original AvatarComponent modifier routine, with a zero-count modifier
        -- descriptor, copies the base record into an engine-owned local override.
        s.native.ensure_override(s.manager,s.entity)
        state.slope_overrides=(state.slope_overrides or 0)+1
        local previous=s
        s=A.snapshot(api,game,exe)
        if not s or not same(api,previous.key,s.key) or not s.cells.enter or not s.manual or not s.eligible then return true end
        if s.enter~=45 or s.exit~=40 or math.abs(f(s.values.slope)-math.cos(50*math.pi/180))>0.001 then return true end
        if kind=='ledge' and (not s.ground or math.abs(s.ground_max-1.95)>0.001) then return true end
    end
    if not guarded(api,s) then return true end
    lease={key=s.key,handle=s.handle,object=s.object,anchor=s.root,started=now,kind=kind,phase='attempt',writes={}}
    state.slope_lease=lease
    state.assist_intent=nil
    local values={enter=65,exit=60,slope=COS,height=2.5}
    local names=kind=='ledge' and {'height'} or {'enter','exit','slope'}
    for _,name in ipairs(names) do
        local address=s.cells[name]
        local w={name=name,before=s.values[name],after=bytes(values[name]),partial=true}
        if not guarded(api,s) or api.read(address,4)~=w.before or not api.writable_data(address,4) then
            return finish('slope_changed_before_commit')
        end
        lease.writes[#lease.writes+1]=w
        if not api.write(address,w.after) or api.read(address,4)~=w.after then
            local restored=A.stop(api,game,exe,state)
            return false,restored and 'slope_write_failed' or 'slope_restore_failed'
        end
        w.partial=false
    end
    if not guarded(api,s) then return finish('slope_changed_after_commit') end
    state.slope_arms=(state.slope_arms or 0)+1
    if kind=='ledge' then state.ledge_arms=(state.ledge_arms or 0)+1 end
    state.slope_status='attempt'
    return true
end
return A
