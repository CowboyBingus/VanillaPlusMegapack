local source,fixtures=assert(arg[1]),assert(arg[2])
local M=dofile(source..'/corpse_data.lua')
local captured=dofile(fixtures..'/captured.lua')
local function clone(x)
    if type(x)~='table' then return x end
    local y={};for k,v in pairs(x) do y[k]=clone(v) end;return y
end
local function find(actions,id)
    for _,a in ipairs(actions) do if a.actor.id==id then return a end end
end
local bad=captured.impaler_late
local actions=M.plan(bad)
local leg=assert(find(actions,0x900264e8),'Recorded detached leg must be repaired')
assert(leg.kind=='pose' and leg.gap>26 and leg.gap<28)
for i=1,3 do assert(leg.position[i]==leg.actor.node_pose[12+i]) end
local claws=0
for _,a in ipairs(actions) do
    assert(not a.actor.registered and a.actor.enabled and a.actor.stable)
    if a.kind=='disable' then claws=claws+1 else assert(a.actor.motion==0) end
end
assert(claws==3,'All three revived tentacle claws must be suppressed')
local marker=assert(find(M.plan(captured.impaler_marker),0x900264e8))
assert(marker.gap>11 and marker.gap<12)
assert(#M.plan(captured.titan_alive)==0,'Parked ragdoll bodies are not dead actors')

-- The Titan capture is a baseline, not a confirmed 27 m Titan reproduction.
-- Apply the measured failure pattern to one of its authored static proxies.
local titan=clone(captured.titan_settled)
local target
for _,a in ipairs(titan.actors) do
    if M.profiles[titan.resource].actors[a.name]==a.node_hash and a.enabled and not a.registered and a.motion==0 then
        if M.rigid(a.node_pose) then target=a;break end
    end
end
assert(target)
target.pose=clone(target.node_pose);target.pose[13]=target.pose[13]+27
local repair=assert(find(M.plan(titan),target.id))
assert(repair.kind=='pose' and math.abs(repair.gap-27)<.0001)
target.pose=clone(target.node_pose)
assert(not find(M.plan(titan),target.id),'Aligned static collider must not be rewritten')
for _,change in ipairs({function(u)u.settled=false end,function(u)u.main_enabled=0 end,
    function(u)u.main_enabled=14 end,function(u)u.main_static=14 end,function(u)u.resource='unrelated' end}) do
    local u=clone(bad);change(u);assert(#M.plan(u)==0)
end
for _,change in ipairs({function(a)a.enabled=false end,function(a)a.stable=false end,
    function(a)a.registered=true end,function(a)a.node_hash=0 end,function(a)a.motion=7 end,
    function(a)a.node_pose[13]=0/0 end,function(a)a.node_pose[1]=0;a.node_pose[2]=0;a.node_pose[3]=0 end}) do
    local u=clone(bad)
    for _,a in ipairs(u.actors) do if a.id==0x900264e8 then change(a) end end
    assert(not find(M.plan(u),0x900264e8))
end
local p,q=M.rigid({0,2,0,0,-3,0,0,0,0,0,4,0,5,6,7,1})
assert(p[1]==5 and p[3]==7 and math.abs(q[3]-math.sqrt(.5))<1e-6 and math.abs(q[4]-math.sqrt(.5))<1e-6)
for axis=1,3 do
    local mat={-1,0,0,0,0,-1,0,0,0,0,-1,0,0,0,0,1}
    mat[(axis-1)*4+axis]=1
    local pos,rot=M.rigid(mat);assert(pos and math.abs(math.abs(rot[axis])-1)<1e-6)
end
assert(not M.rigid({-1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}),'Mirrored/nonrigid basis rejected')

-- Command submission must recheck identity, never fall back to raw writes.
local original=M.snapshot
local function submit(stale)
    local unit=clone(bad);unit.guards={{address=1,bytes='unit'}}
    for _,a in ipairs(unit.actors) do a.guards={{address=a.id,bytes='actor'}} end
    M.snapshot=function()return {unit},'ready' end
    local state={native={pose=function(id,p,q)assert(id~=stale) end,disable=function(id)assert(id~=stale) end}}
    local api={read=function(addr)return addr==stale and 'changed' or addr==1 and 'unit' or 'actor' end}
    assert(M.apply(api,0,0,state))
    return state
end
assert(submit(0).realignments>0)
assert(submit(0x900264e8).skipped==1)
assert(submit(1).realignments==nil)
M.snapshot=original
print('PASS: recorded 11/27 m Impaler repair, three claw actors, Titan regression pattern, living/dynamic/disabled exclusions, rigid transforms and command identity checks')
