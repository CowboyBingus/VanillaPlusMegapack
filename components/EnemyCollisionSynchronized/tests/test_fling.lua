local source=assert(arg[1])
local M=dofile(source..'/corpse_data.lua')
local function clone(x)
    if type(x)~='table' then return x end
    local y={};for k,v in pairs(x) do y[k]=clone(v) end;return y
end
local function matrix(x,degrees)
    local c,s=math.cos(math.rad(degrees or 0)),math.sin(math.rad(degrees or 0))
    return {c,s,0,0,-s,c,0,0,0,0,1,0,x or 0,0,0,1}
end
local function unit(resource)
    local count=M.profiles[resource].bodies
    local u={unit=99,id=77,resource=resource,settled=true,corpse=false,owner=false,active=true,
        update_enabled=true,main_enabled=count,main_static=count,main_signature='same 15 handles',
        root_body={id=42,pose=matrix()},actors={},guards={{address=1,bytes='identity'}},
        manager=100,index=2,update_address=3}
    u.main_bodies={u.root_body}
    for i=2,count do u.main_bodies[i]={id=42+i,pose=matrix()} end
    return u
end
local function arm(u,state)
    assert(not M.fling_action(u,state,0))
    assert(not M.fling_action(u,state,.5))
    assert(not M.fling_action(u,state,1))
    assert(state.fling_history[u.unit].armed)
end
local targets={};for resource in pairs(M.profiles) do targets[#targets+1]=resource end
for _,resource in ipairs(targets) do
    local u,state=unit(resource),{}
    arm(u,state);u.root_body.pose=matrix(1)
    local stop=assert(M.fling_action(u,state,1.2));assert(stop.cause=='translation' and stop.distance==1)
    u,state=unit(resource),{};arm(u,state);u.root_body.pose=matrix(0,25)
    stop=assert(M.fling_action(u,state,1.2));assert(stop.cause=='rotation' and math.abs(stop.degrees-25)<1e-6)
    -- Initial death motion and final corrections must finish before arming.
    u,state=unit(resource),{}
    for i=0,10 do u.root_body.pose=matrix(i);assert(not M.fling_action(u,state,i*.2)) end
    assert(not state.fling_history[u.unit].armed)
    for i=11,16 do assert(not M.fling_action(u,state,i*.2)) end
    assert(state.fling_history[u.unit].armed)
    -- An armed corpse accepts small corrections without changing its baseline.
    u,state=unit(resource),{};arm(u,state);u.root_body.pose=matrix(.2,3)
    assert(not M.fling_action(u,state,1.2))
    for _,change in ipairs({function(v)v.owner=true end,function(v)v.active=false end,
        function(v)v.update_enabled=false end,function(v)v.main_static=v.main_static-1 end,
        function(v)v.main_enabled=v.main_enabled-1 end,function(v)v.settled=false end,function(v)v.corpse=true end,
        function(v)v.resource='unknown' end,function(v)v.root_body.pose[13]=0/0 end}) do
        u,state=unit(resource),{};arm(u,state);u.root_body.pose=matrix(10);change(u)
        assert(not M.fling_action(u,state,1.2) and state.fling_history[u.unit]==nil)
    end
    for _,change in ipairs({function(v)v.id=v.id+1 end,function(v)v.root_body.id=43 end,
        function(v)v.main_signature='replaced limb' end}) do
        u,state=unit(resource),{};arm(u,state);u.root_body.pose=matrix(10);change(u)
        assert(not M.fling_action(u,state,1.2))
        assert(not state.fling_history[u.unit] or not state.fling_history[u.unit].armed)
    end
    u,state=unit(resource),{};arm(u,state);u.root_body.pose=matrix(10)
    assert(not M.fling_action(u,state,2.01),'Gaps lose the stationary reference')
    assert(not state.fling_history[u.unit].armed)
    u,state=unit(resource),{};arm(u,state);u.root_body.pose=matrix(10)
    assert(not M.fling_action(u,state,.1),'Clock rollback loses the stationary reference')
end

local state

-- Exercise actual command integration: one native stop, read-back confirmation,
-- no main-body pose/enable changes, and no use of a stale manager or owner.
local original=M.snapshot
for _,variant in ipairs({'normal','stale','owner','unconfirmed'}) do
    local u=unit(targets[1]);local now,enabled,calls,stale=0,true,0,false
    local api={time=function()return now end,read=function(address)
        if address==1 then return stale and 'changed' or 'identity' end
        if address==3 then return enabled and '\1' or '\0' end
    end}
    state={native={stop_sync=function(manager,index)
        assert(manager==100 and index==2);calls=calls+1
        if variant~='unconfirmed' then enabled=false end
    end,pose=function()error('No main pose rewrite')end,disable=function()error('No main collision removal')end}}
    M.snapshot=function()u.update_enabled=enabled;return {u},'ready' end
    for _,t in ipairs({0,.5,1}) do now=t;M.apply(api,0,0,state) end
    now=1.2;u.root_body.pose=matrix(1)
    stale=variant=='stale';u.owner=variant=='owner'
    M.apply(api,0,0,state)
    if variant=='normal' or variant=='unconfirmed' then
        assert(calls==1 and state.fling_stops==1)
        assert((state.fling_stops_verified or 0)==(variant=='normal' and 1 or 0))
        if variant=='normal' then
            now=1.4;M.apply(api,0,0,state);assert(calls==1,'Stopped component cannot stop again')
            now=101.6;u.owner=true;M.apply(api,0,0,state)
            assert(calls==2 and state.fling_handoffs==1 and state.fling_stopped[u.unit]==nil,
                'Ownership gain finishes only our previous stop through native cleanup')
            now=101.8;M.apply(api,0,0,state);assert(calls==2,'Handoff cleanup is not repeated')
        end
    else assert(calls==0) end
    now=5;M.snapshot=function()return {},'waiting_for_mission' end;M.apply(api,0,0,state)
    assert(next(state.fling_history)==nil and next(state.fling_stopped)==nil,'Mission exit clears history')
end
M.snapshot=original
print('PASS: 21-profile fling policy, initial-motion/small-correction exclusions, identity/ownership/gap resets and native-stop integration')
