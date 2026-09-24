local ffi=require('ffi')
local source=assert(arg[1])
local M=dofile(source..'/corpse_data.lua')
local function fixture(corpse,native_pointers,resource)
    resource=resource or '\059\238\251\018\066\231\248\220'
    local profile=M.profiles[resource];local count=profile.bodies;local extra=count+1
    local aux,node=next(profile.actors)
    if profile.name=='Impaler' then aux,node=0x70f1db61,0x9b47948d end
    local blocks,alloc={},native_pointers and 0x20000000000 or 0x30000000
    local function address(a)return type(a)=='cdata' and tonumber(ffi.cast('uintptr_t',a)) or a end
    local function add(address,size)
        local b={address=address,size=size,bytes=ffi.new('uint8_t[?]',size)};blocks[#blocks+1]=b;return address,b
    end
    local function reserve(size)local a=alloc;alloc=alloc+0x100000;return add(a,size) end
    local function write(address,bytes)
        for _,b in ipairs(blocks) do
            if address>=b.address and address+#bytes<=b.address+b.size then
                ffi.copy(b.bytes+address-b.address,bytes,#bytes);return
            end
        end
        error('Fixture write out of range '..address)
    end
    local function number(address,kind,n)local v=ffi.new(kind..'[1]',n);write(address,ffi.string(v,ffi.sizeof(v))) end
    local function u(address,n)number(address,'uint32_t',n) end
    local function p(address,n)number(address,'uint64_t',n) end
    local function matrix(address,x,y,z)
        local v=ffi.new('float[16]',{1,0,0,0,0,1,0,0,0,0,1,0,x or 0,y or 0,z or 0,1})
        write(address,ffi.string(v,64))
    end
    local game,exe=native_pointers and 0x7ff800000000 or 0x10000000,native_pointers and 0x7ff700000000 or 0x20000000
    local function global(base,rva,target)add(base+rva,8);p(base+rva,target) end
    local mode=reserve(0x44);u(mode+8,1);u(mode+0x40,1);global(game,0x33266a0,mode)
    local rm,cm=reserve(88),reserve(88);global(game,0x3326948,rm);global(game,0x3326920,cm)
    local manager=corpse and cm or rm;local entities=reserve(8);local entity=reserve(24)
    write(entity,resource);u(entity+8,37);u(entity+12,0x400007);u(entity+16,99)
    local runtime=reserve(corpse and 72 or 11192);local sync=reserve(corpse and 56 or 432)
    u(manager+(corpse and 16 or 4),1);u(manager+(corpse and 24 or 12),1);u(manager+(corpse and 28 or 16),1)
    p(manager+(corpse and 64 or 56),entities);p(entities,entity);p(manager+72,runtime);p(manager+80,sync)
    if not corpse then
        u(runtime+11160,count);write(runtime+11172,'\1\0');u(sync,count);u(sync+184,count)
        for i=0,count-1 do u(runtime+i*712,0x90000001+i) end
    end
    local registry=reserve(0xa8);global(exe,0x1a100f0,registry)
    local generations,slots=reserve(32),reserve(32*8);p(registry+0xa0,generations);p(registry+0x88,slots);u(registry+0x98,32)
    write(generations+7,'\1');local object=reserve(0x100);p(slots+56,object);u(object+8,0x400007)
    local nodes=reserve(profile.nodes*64);u(object+0x70,profile.nodes);p(object+0x88,nodes);matrix(nodes+72*64,-161.2,107.25,20.17)
    local lists=reserve(32*24);global(exe,0x27c5b40,lists)
    local list=lists+7*24;u(list,0x400007);u(list+4,0x40000000+extra)
    local handles=reserve(32*4);p(list+8,handles)
    local pool=exe+0x2369b00+64*21;add(pool,56)
    local actors=reserve(32*40);p(pool,actors);u(pool+28,40);u(pool+36,32);u(pool+40,255);u(pool+52,0xc0000000)
    local world,vt,bodies=reserve(64),reserve(144),reserve(32*160)
    global(exe,0x27ba8a8+176*2,world);p(world,vt);p(vt+136,exe+0xd0cfa0);p(world+24,bodies)
    for index=1,extra do
        local id=0x90000000+index;u(handles+4*(index-1),id)
        local a=actors+40*index;u(a,id);u(a+12,0x400007);u(a+16,1);u(a+20,index)
        u(a+24,index==extra and aux or profile.main[index]);u(a+28,index==extra and 72 or 0)
        u(a+32,index==extra and node or profile.main[index])
        local b=bodies+160*index;matrix(b,index==extra and -183.4 or 0,index==extra and 119.01 or 0,index==extra and 30.1 or 0)
        u(b+108,index==extra and 20 or corpse and 48 or 52);u(b+144,id);u(b+148,0x400007)
    end
    local api={}
    function api.read(address,size)
        address=type(address)=='cdata' and tonumber(ffi.cast('uintptr_t',address)) or address
        for _,b in ipairs(blocks) do
            if address>=b.address and address+size<=b.address+b.size then return ffi.string(b.bytes+address-b.address,size) end
        end
    end
    function api.pointer(bytes,offset)
        if not bytes then return nil end
        local v=ffi.new('uint64_t[1]');ffi.copy(v,bytes:sub((offset or 0)+1),8)
        return v[0]~=0 and tonumber(v[0]) or nil
    end
    function api.distance(a,b)return a-b end
    api.address=address
    if native_pointers then
        local production=dofile(source..'/windows_api.lua')()
        api.pointer,api.distance,api.address=production.pointer,production.distance,production.address
        -- Keep this regression executable against v2, which predates address().
        api.address=api.address or address
        game,exe=ffi.cast('uint8_t *',game),ffi.cast('uint8_t *',exe)
    end
    return api,game,exe,{write=write,u=u,manager=manager,runtime=runtime,sync=sync,generation=generations+7,
        actor=actors+extra*40,body=bodies+extra*160,main=actors+40,entity=entity,mode=mode,
        main_body=bodies+160,matrix=matrix,getter=vt+136,p=p,exe=address(exe),
        list=list,handles=handles,actors=actors,bodies=bodies}
end

-- In the observed session the active-state field was 1 in mission and 0 on
-- the ship; field +0x40 remained 2 in both. It cannot require the literal 1.
for _,corpse in ipairs({false,true}) do
    local api,g,e,f=fixture(corpse,true)
    f.u(f.mode+0x40,2)
    local units,status=M.snapshot(api,g,e,{})
    assert(status=='ready' and #units==1,'Recorded mode field 2 must not block an active mission')
    f.u(f.mode+8,0)
    assert(not M.same(api,units[1].guards),'Mission exit invalidates a pending unit snapshot')
    units,status=M.snapshot(api,g,e,{})
    assert(status=='waiting_for_mission' and #units==0,'Captured ship state remains excluded')
end

-- Recorded disabled tentacle actors retain their actor identity but have
-- a differently tagged body ID (0x9000... -> 0xd000...). They are not repair
-- targets and must not prevent a healthy enabled actor from being repaired.
for _,corpse in ipairs({false,true}) do
    local api,g,e,f=fixture(corpse,true)
    local id=0x90000011
    f.u(f.list+4,0x40000011);f.u(f.handles+16*4,id)
    local actor,body=f.actors+17*40,f.bodies+17*160
    f.u(actor,id);f.u(actor+12,0x400007);f.u(actor+16,0);f.u(actor+20,17)
    f.u(actor+24,0x1245edba);f.u(body+64,1998);f.u(body+108,22)
    f.u(body+144,0xd0000011);f.u(body+148,0x400007)
    local state={};local units=M.snapshot(api,g,e,state)
    assert(#units==1 and #M.plan(units[1])==1,'Disabled tagged body must not reject the whole corpse: '..tostring(state.last_skip))
    assert(units[1].main_enabled==15 and units[1].main_static==15)
    f.u(actor+16,1);units=M.snapshot(api,g,e,{})
    assert(#units==0,'Enabled actor with a mismatched body still rejects the snapshot')
end

-- The in-game formatter is not established by this fixture. A deliberately
-- lossy formatter reproduces v2's exact rejection and verifies that formatted
-- pointer text is no longer used as cache identity. Use real-width pointers
-- and the production pointer/distance adapter, not numeric-only mock addresses.
local lossy_env=setmetatable({tostring=function(value)
    if type(value)=='cdata' then return 'cdata<pointer>' end
    return tostring(value)
end},{__index=_G})
local lossy=setfenv(assert(loadfile(source..'/corpse_data.lua')),lossy_env)()
for _,corpse in ipairs({false,true}) do
    local api,g,e,f=fixture(corpse,true)
    for pass=1,80 do
        local state={};local units=lossy.snapshot(api,g,e,state)
        assert(#units==1,'Pointer-cache regression: '..tostring(state.last_skip))
        assert(#lossy.plan(units[1])==1)
        assert(state.preflight_getter=='verified' and state.getter_checks==17)
    end
    f.u(f.mode+8,0)
    local state={};local units,status=lossy.snapshot(api,g,e,state)
    assert(status=='waiting_for_mission' and #units==0 and state.preflight_getter=='verified'
        and state.getter_checks==1,'Ship preflight exercises the actual getter path')
    f.p(f.getter,f.exe+0xd11661)
    state={};local ok,reason=pcall(lossy.snapshot,api,g,e,state)
    assert(not ok and tostring(reason):find('Body getter changed',1,true))
    assert(state.getter_failures==1 and state.last_getter_failure:find('world_index=2',1,true)
        and state.last_getter_failure:find('offset=13702753',1,true),'Changed getter remains rejected with actual values')
end
for _,corpse in ipairs({false,true}) do
    local api,g,e,f=fixture(corpse);local state={}
    local units,status=M.snapshot(api,g,e,state)
    assert(status=='ready' and #units==1 and units[1].main_enabled==15 and units[1].main_static==15)
    assert(units[1].owner==false and units[1].active and units[1].manager==f.manager and units[1].index==0)
    if not corpse then
        assert(units[1].root_body.id==0x90000001 and units[1].update_enabled)
        assert(#units[1].main_bodies==15 and #units[1].main_pose_guards==15)
        f.matrix(f.main_body+160,.6)
        assert(not M.same(api,units[1].main_pose_guards),'Independent limb pose invalidates stop observation')
        assert(M.same(api,units[1].root_body.guards),'Root guard alone misses a changed limb')
        f.matrix(f.main_body+160,0)
        assert(units[1].update_address==f.runtime+11172 and units[1].main_signature)
        f.write(f.runtime+11172,'\0');units=M.snapshot(api,g,e,{})
        assert(#units==1 and not units[1].update_enabled and #M.plan(units[1])==1,
            'Auxiliary repair continues after native sync stop')
        f.write(f.runtime+11172,'\1')
    end
    local actions=M.plan(units[1]);assert(#actions==1 and actions[1].gap>26)
    f.u(f.body+148,0)
    assert(not M.same(api,actions[1].actor.guards),'Auxiliary body reassignment invalidates a pending repair')
    f.u(f.body+148,0x400007)
    f.u(f.main+16,0);units=M.snapshot(api,g,e,{})
    assert(#units==1 and #M.plan(units[1])==0,'Sinking must not resurrect collision')
    f.u(f.main+16,1);f.write(f.generation,'\2');units=M.snapshot(api,g,e,{})
    assert(#units==0,'Reused unit generation rejected')
    f.write(f.generation,'\1');f.u(f.body+148,0);units=M.snapshot(api,g,e,{})
    assert(#units==0,'Body reassigned to another unit rejected')
end
local api,g,e,f=fixture(false)
f.u(f.sync,0);f.u(f.sync+184,0)
local history={fling_history={[0x400007]={armed=true}}}
assert(#M.snapshot(api,g,e,history)==0,'Living zero-count ragdoll excluded')
assert(history.fling_history[0x400007]==nil,'Observed lifecycle changes clear any prior stationary reference')
f.u(f.sync,15);f.u(f.sync+184,7)
assert(#M.snapshot(api,g,e,{})==0,'Mixed pose counts excluded')
f.u(f.sync+184,15);f.write(f.runtime+11173,'\1')
assert(#M.snapshot(api,g,e,{})==0,'First-stop correction excluded')
f.write(f.runtime+11173,'\0');f.u(f.mode+8,0)
local units,status=M.snapshot(api,g,e,{})
assert(#units==0 and status=='waiting_for_mission')

-- Use the actual reader and planner together for the new stop. The stubbed
-- native routine changes the same update flag; handoff simulates removal.
api,g,e,f=fixture(false)
local now,stops=0,0
api.time=function()return now end
local state={native={pose=function()end,disable=function()error('No claws in fixture')end,
    stop_sync=function(manager,index)
        assert(manager==f.manager and index==0);stops=stops+1
        f.write(f.runtime+11172,'\0')
        if stops==2 then f.u(f.manager+12,0);f.u(f.manager+16,0) end
    end}}
for _,t in ipairs({0,.5,1}) do now=t;assert(M.apply(api,g,e,state)) end
assert(state.fling_armed==1 and stops==0)
f.matrix(f.main_body,1);now=1.2;assert(M.apply(api,g,e,state))
assert(stops==1 and state.fling_stops_verified==1)
now=1.4;assert(M.apply(api,g,e,state));assert(stops==1)
f.u(f.entity+20,1);now=1.6;assert(M.apply(api,g,e,state))
assert(stops==2 and state.fling_handoffs==1)
now=1.8;assert(M.apply(api,g,e,state));assert(stops==2)

-- Full reader -> limb guard -> native command, with a stable root. Recheck
-- every sampled main pose before acting; a changed limb must cancel the stop.
for _,stale in ipairs({false,true}) do
    api,g,e,f=fixture(false);now=0;stops=0
    api.time=function()return now end
    local state={native={pose=function()end,disable=function()error('No claws')end,
        stop_sync=function()stops=stops+1;f.write(f.runtime+11172,'\0')end}}
    for _,t in ipairs({0,.5,1}) do now=t;M.apply(api,g,e,state) end
    f.matrix(f.main_body+160,.6);now=1.2;M.apply(api,g,e,state);assert(stops==0)
    local original=M.snapshot
    if stale then M.snapshot=function(a,g,e,s,consume,budget)
        return original(a,g,e,s,function(u)f.matrix(f.main_body+160,1.7);consume(u)end,budget)
    end end
    now=1.4;M.apply(api,g,e,state);M.snapshot=original
    assert(stops==(stale and 0 or 1))
    if not stale then
        assert(state.fling_limb_stops==1 and state.fling_stops_verified==1)
        assert(state.last_fling_actor==0x90000002 and state.last_fling_reason=='limb_translation')
    else assert(state.fling_history[0x400007]==nil) end
end
-- Exercise every real layout through the memory reader, including corpse
-- profiles with no filter override (tripods) and the war-machine filter 83.
local profiles_checked=0
for resource,profile in pairs(M.profiles) do
    profiles_checked=profiles_checked+1
    for _,corpse in ipairs({false,true}) do
        local api,g,e,f=fixture(corpse,true,resource)
        for _,filter in ipairs({0,48,83}) do
            for i=1,profile.bodies do f.u(f.bodies+i*160+108,filter) end
            local units=M.snapshot(api,g,e,{})
            assert(#units==1 and units[1].main_enabled==profile.bodies and #M.plan(units[1])==1,
                profile.name..': primary membership must not depend on corpse filter')
        end
        local disabled,forbidden=0,{}
        for i,name in ipairs(profile.main) do
            if profile.disabled_main[name] then
                f.u(f.actors+i*40+16,0);disabled=disabled+1
                forbidden[#forbidden+1]=f.bodies+i*160
            end
        end
        local read=api.read
        api.read=function(address,size)
            address=api.address(address)
            for _,body in ipairs(forbidden) do
                assert(address+size<=body or address>=body+160,'Disabled Havok body must not be read')
            end
            return read(address,size)
        end
        local units=M.snapshot(api,g,e,{})
        assert(#units==1 and units[1].main_disabled==disabled)
        assert(units[1].main_static==profile.bodies-disabled and #M.plan(units[1])==1)
        -- A missing primary cannot masquerade as a declared disabled primary.
        f.u(f.handles,0xffffffff);units=M.snapshot(api,g,e,{})
        assert(#units==1 and #M.plan(units[1])==0)
    end
    local api,g,e,f=fixture(false,true,resource)
    f.u(f.runtime+11160,profile.bodies-1)
    assert(#M.snapshot(api,g,e,{})==0,'Unexpected runtime count must reject '..profile.name)
    f.u(f.runtime+11160,profile.bodies);f.u(f.main+24,0x12345678)
    assert(#M.snapshot(api,g,e,{})==0,'Unexpected primary name must reject '..profile.name)
    if next(profile.disabled_main) and not profile.finish_disabled then
        -- The assault walker's four authored landing disables must not block
        -- detection on its six remaining static bodies, or expose their old
        -- Havok slots. This exercises the real reader and command path.
        local api,g,e,f=fixture(false,true,resource)
        local disabled,limb={},nil
        for i,name in ipairs(profile.main) do
            if profile.disabled_main[name] then
                f.u(f.actors+i*40+16,0);disabled[#disabled+1]=f.bodies+i*160
            elseif i>1 then limb=f.bodies+i*160 end
        end
        local read=api.read
        api.read=function(address,size)
            local n=api.address(address)
            for _,body in ipairs(disabled) do assert(n+size<=body or n>=body+160) end
            return read(address,size)
        end
        local now,stops=0,0
        api.time=function()return now end
        local state={native={pose=function()end,disable=function()error('No added collision changes')end,
            stop_sync=function()stops=stops+1;f.write(f.runtime+11172,'\0')end}}
        for _,t in ipairs({0,.5,1}) do now=t;M.apply(api,g,e,state) end
        assert(stops==0 and state.fling_armed==1)
        f.matrix(assert(limb),.6);now=1.2;M.apply(api,g,e,state);assert(stops==0)
        now=1.4;M.apply(api,g,e,state)
        assert(stops==1 and state.fling_limb_stops==1 and state.fling_stops_verified==1)
    end
    if profile.finish_disabled then
        for _,variant in ipairs({'normal','owner','living','first_stop','gap','re_enabled','stale'}) do
            local api,g,e,f=fixture(false,true,resource)
            for i=1,profile.bodies do f.u(f.actors+i*40+16,0) end
            local read=api.read
            api.read=function(address,size)
                local n=api.address(address)
                assert(n+size<=f.main_body or n>=f.main_body+profile.bodies*160,
                    'All-disabled completion cannot touch disabled Havok storage')
                return read(address,size)
            end
            local now,stops,requests=0,0,0
            api.time=function()return now end
            local state={native={pose=function()end,disable=function()error('No collision changes')end,
                stop_sync=function()stops=stops+1;f.write(f.runtime+11172,'\0')end,
                request_completion=function(id)assert(id==37);requests=requests+1 end}}
            if variant=='owner' then f.u(f.entity+20,1)
            elseif variant=='living' then f.u(f.sync,0);f.u(f.sync+184,0)
            elseif variant=='first_stop' then f.write(f.runtime+11173,'\1') end
            for _,t in ipairs({0,.5}) do now=t;M.apply(api,g,e,state) end
            assert(stops==0)
            local original=M.snapshot
            if variant=='stale' then M.snapshot=function(a,g,e,s,consume,budget)
                return original(a,g,e,s,function(u)f.u(f.entity+16,100);consume(u)end,budget)
            end end
            if variant=='re_enabled' then
                f.u(f.main+16,1);api.read=read
            end
            now=variant=='gap' and 2 or 1;M.apply(api,g,e,state);M.snapshot=original
            assert(stops==(variant=='normal' and 1 or 0),profile.name..': '..variant)
            if variant=='normal' then
                assert(state.landed_disabled_stops==1 and state.fling_stops_verified==1)
                now=1.999;M.apply(api,g,e,state);assert(requests==0)
                now=2;M.apply(api,g,e,state);assert(requests==1)
                now=3;M.apply(api,g,e,state);assert(stops==1 and requests==1)
            end
        end
    end
end
assert(profiles_checked==21)
print('PASS: 21 profile layouts, variable body counts, authored disabled bodies without Havok reads, tripod completion/guards, native snapshots, identity and lifecycle exclusions')
