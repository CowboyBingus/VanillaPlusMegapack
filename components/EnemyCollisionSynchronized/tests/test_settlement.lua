local source,fixtures=assert(arg[1]),assert(arg[2])
local M=dofile(source..'/corpse_data.lua')
local function matrix(x,y,angle)
    local c,s=math.cos(math.rad(angle or 0)),math.sin(math.rad(angle or 0))
    return {c,s,0,0,-s,c,0,0,0,0,1,0,x or 0,y or 0,0,1}
end
local function unit(resource)
    local count=M.profiles[resource].bodies
    local bodies={{id=1,pose=matrix()}}
    for i=2,count do bodies[i]={id=i,pose=matrix(10)} end
    return {unit=99,id=77,resource=resource,settled=true,corpse=false,owner=false,active=true,
        update_enabled=true,main_enabled=count,main_static=count,main_signature='1:2:3:4:5:6:7:8:9:10:11:12:13:14:15',
        main_bodies=bodies,root_body=bodies[1]}
end
local function arm(u,state)
    for _,t in ipairs({0,.5,1}) do assert(not M.fling_action(u,state,t)) end
    assert(state.fling_history[u.unit].armed)
end
for resource in pairs(M.profiles) do
    local last=M.profiles[resource].bodies
    for _,kind in ipairs({'translation','rotation'}) do
        local u,state=unit(resource),{}
        arm(u,state)
        u.main_bodies[last].pose=kind=='translation' and matrix(10.6) or matrix(10,0,20)
        assert(not M.fling_action(u,state,1.2),'One limb observation must not stop a corpse')
        assert(not M.fling_action(u,state,1.25),'Confirmation must span at least 100 ms')
        local a=assert(M.fling_action(u,state,1.31))
        assert(a.cause=='limb_'..kind and a.actor==last and a.distance==0 and a.degrees==0)
        assert(kind=='translation' and a.limb_distance>.59 or kind=='rotation' and a.limb_degrees>19.9)
    end
    -- A transient displacement, changing actor, or invalid matrix is not a
    -- confirmed independent limb excursion.
    local u,state=unit(resource),{};arm(u,state)
    u.main_bodies[last].pose=matrix(11);assert(not M.fling_action(u,state,1.2))
    u.main_bodies[last].pose=matrix(10);assert(not M.fling_action(u,state,1.4))
    u.main_bodies[last].pose=matrix(11);assert(not M.fling_action(u,state,1.6))
    u.main_bodies[last].pose=matrix(10);u.main_bodies[last-1].pose=matrix(11)
    assert(not M.fling_action(u,state,1.8),'A different limb cannot inherit confirmation')
    for _,change in ipairs({function(v)v.main_bodies[last]=nil end,
        function(v)v.main_bodies[last].pose[1]=0/0 end,
        function(v)v.main_bodies[last].id=last-1 end}) do
        u,state=unit(resource),{};arm(u,state);change(u)
        assert(not M.fling_action(u,state,1.2) and state.fling_history[u.unit]==nil)
    end
    -- A whole-body turn under the root threshold can move a long limb tip
    -- several metres. Its shape relative to the root has not changed.
    u,state=unit(resource),{};arm(u,state)
    local angle=math.rad(17)
    u.root_body.pose=matrix(.2,0,17)
    for i=2,last do u.main_bodies[i].pose=matrix(.2+10*math.cos(angle),10*math.sin(angle),17) end
    for _,t in ipairs({1.2,1.4,1.6}) do assert(not M.fling_action(u,state,t)) end
    -- Initial dynamic death and observation gaps must still lose history.
    u,state=unit(resource),{};arm(u,state);u.main_bodies[last].pose=matrix(12)
    assert(not M.fling_action(u,state,1.2));u.main_static=last-1
    assert(not M.fling_action(u,state,1.4) and state.fling_history[u.unit]==nil)
    u,state=unit(resource),{};arm(u,state);u.main_bodies[last].pose=matrix(12)
    assert(not M.fling_action(u,state,1.2));assert(not M.fling_action(u,state,2.3))
    assert(not state.fling_history[u.unit].armed)
end

local function replay(name)
    local rows=dofile(fixtures..'/'..name..'.lua')
    local state,stops,seen={},{},{}
    for _,r in ipairs(rows) do
        local resource=r.resource:gsub('0x',''):gsub('..',function(s)return string.char(tonumber(s,16))end):reverse()
        assert(M.profiles[resource],'Fixture must preserve the exact 64-bit resource hash')
        local u=unit(resource);u.unit=r.unit;u.id=r.entity
        u.main_bodies=r.poses;u.root_body=r.poses[1]
        local ids={};for _,b in ipairs(r.poses) do ids[#ids+1]=b.id end
        u.main_signature=table.concat(ids,':');seen[u.unit]=true
        if not stops[u.unit] then
            local a=M.fling_action(u,state,r.time)
            if a then stops[u.unit]={seq=r.seq,time=r.time,action=a,name=r.name} end
        end
    end
    local units,count=0,0;for _ in pairs(seen) do units=units+1 end;for _ in pairs(stops) do count=count+1 end
    return rows,stops,units,count
end
local rows,stops,units,count=replay('settlement_latest')
assert(#rows==299 and units==32 and count==11)
-- Recovered pre-Corpse limb episodes: the root stays under the original
-- trigger while substantial independent articulation now receives a stop.
assert(stops[0x34003bf].seq==952 and stops[0x34003bf].action.cause=='limb_rotation')
assert(stops[0x34003bf].action.distance<.1 and stops[0x34003bf].action.limb_degrees>20)
assert(stops[0x1c03ad4].seq==4499 and stops[0x1c03ad4].action.cause=='limb_rotation')
assert(stops[0x1c03ad4].action.degrees<20)
local impalers,titans=0,0
for _,stop in pairs(stops) do
    if stop.name=='Impaler' then impalers=impalers+1 else titans=titans+1 end
end
print('REPLAY: latest 299 strict samples / 32 units; '..count..' detections ('..titans..' Titans, '..impalers..' Impalers)')
rows,stops,units,count=replay('settlement_control')
assert(#rows==10 and units==1 and count==0,'Healthy Impaler control remains unchanged')
print('PASS: 21-profile independent limb translation/rotation, persistent confirmation, coherent whole-body motion, invalid poses/lifecycle/gaps, latest recording and healthy Impaler control')
