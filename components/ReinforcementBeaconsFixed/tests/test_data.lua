local source,fixture=arg[1],arg[2]
local ffi=require('ffi')
local patch=assert(loadfile(source..'/spawn_data.lua'))()
local function snapshot(state,count)
    return {identity='mission',id=1,owned=true,mode=1,count=count or 2,state=state,
        use_bit=0,countdown=5,position={50,60,4},original='abcdefgh',unit_ref=7,
        automatic={},beacons={}}
end
local function beacon(s,id,used,x,y,owned)
    s.beacons[#s.beacons+1]={id=id,used=used,owned=owned~=false,position={x or 10,y or 20,3}}
end
local tracker={}
local a=snapshot(1);beacon(a,50,0)
assert(not patch.plan(a,tracker))
local b=snapshot(2);beacon(b,50,1)
local plan=assert(patch.plan(b,tracker))
assert(plan.kind=='beacon' and plan.target[1]==10 and plan.target[2]==20)
assert(#plan.bytes==8)
for mode=1,7 do
    local t={};local before=snapshot(1);before.mode=mode;beacon(before,50,0);patch.plan(before,t)
    local now=snapshot(2);now.mode=mode;beacon(now,50,1)
    assert(patch.plan(now,t),'reinforcement rejected valid mission mode '..mode)
end
-- Synthetic regression: local use_bit=0; a teammate-owned beacon
-- retains used=2 throughout the local queue commit.
local remote_before=snapshot(1)
local remote_now=snapshot(2)
remote_now.position={50,60,3}
beacon(remote_now,50,2,10,20,false)
local remote_tracker={};patch.plan(remote_before,remote_tracker)
local remote_plan=assert(patch.plan(remote_now,remote_tracker),'Teammate-owned beacon was skipped')
assert(remote_plan.target[1]==10 and remote_plan.target[2]==20)
-- Native selection is the first unused record in manager order. A previously
-- observed remote choice is usable; newly ambiguous or changed choices are not.
for _,case in ipairs({'observed','ambiguous','disappeared','moved','local_owner','not_dead','late','already_used'}) do
    local t={};local before=snapshot(case=='not_dead' and 3 or case=='late' and 2 or 1)
    if case=='observed' or case=='disappeared' or case=='moved' then
        beacon(before,60,2,10,20,false);beacon(before,61,2,30,40,false)
    end
    patch.plan(before,t)
    local now=snapshot(2)
    if case~='disappeared' then beacon(now,60,case=='already_used' and 3 or 2,case=='moved' and 11 or 10,20,case=='local_owner') end
    if case=='observed' or case=='ambiguous' or case=='disappeared' or case=='moved' then beacon(now,61,2,30,40,false) end
    local selected=patch.plan(now,t)
    if case=='observed' then assert(selected and selected.beacon==60,case)
    elseif case=='already_used' then assert(selected and selected.association=='used',case)
    else assert(not selected,case) end
end
-- Initial drops, ambiguous beacons, used/stale beacons, expired windows, other modes.
for _,case in ipairs({'initial','ambiguous','used','expired','nan','mode','ownership','mission','players'}) do
    local t={};local before=snapshot(case=='initial' and 0 or 1)
    beacon(before,50,case=='used' and 1 or 0);patch.plan(before,t)
    local now=snapshot(2);beacon(now,50,1)
    if case=='ambiguous' then beacon(now,51,1) end
    if case=='expired' then now.countdown=0 end
    if case=='nan' then now.countdown=0/0 end
    if case=='mode' then now.mode=4 end
    if case=='ownership' then now.owned=false end
    if case=='mission' then now.identity='different' end
    if case=='players' then now.count=3 end
    assert(not patch.plan(now,t),case)
end
-- Synthetic solo scenarios: automatic anchors and final pod XY both scattered.
local trace=assert(loadfile(fixture))()
tracker={};local corrections=0
for _,row in ipairs(trace) do
    local plan=patch.plan(row,tracker)
    if plan then
        assert(plan.kind=='solo' and tracker.anchor)
        assert(plan.target[1]==tracker.anchor.source[1] and plan.target[2]==tracker.anchor.source[2])
        assert(plan.target[1]~=row.beacons[1].position[1])
        tracker.pending=plan;corrections=corrections+1
    end
end
assert(corrections==3,'Expected all three synthetic solo scenarios')
-- Solo death anchors must also work in the live-reported defense mode.
tracker={};corrections=0
for _,row in ipairs(trace) do
    row.mode=2
    local plan=patch.plan(row,tracker)
    if plan then
        assert(plan.kind=='solo' and plan.target[1]==tracker.anchor.source[1] and plan.target[2]==tracker.anchor.source[2])
        tracker.pending=plan;corrections=corrections+1
    end
end
assert(corrections==3,'Defense mode lost solo death anchors')
-- Exercise the guarded write with unrelated bytes, Z and countdown as sentinels.
local original_snapshot=patch.snapshot
for _,case in ipairs({'success','changed','mode_changed','readonly','partial','remote','remote_changed','remote_owner_changed'}) do
    local remote=case:find('remote',1,true)~=nil
    local t={};local before=snapshot(1);beacon(before,50,remote and 2 or 0,10,20,not remote);patch.plan(before,t)
    local now=snapshot(2);beacon(now,50,remote and 2 or 1,10,20,not remote);now.address=0x10010c
    local reads,writes=0,{}
    local mem=now.original
    local api={}
    patch.snapshot=function()
        reads=reads+1
        local s=snapshot(2);beacon(s,50,remote and 2 or 1,10,20,not remote);s.address=now.address
        if reads==2 and case=='changed' then s.state=3 end
        if reads==2 and case=='mode_changed' then s.mode=2 end
        if reads==2 and case=='remote_changed' then s.beacons[1].position[1]=11 end
        if reads==2 and case=='remote_owner_changed' then s.beacons[1].owned=true end
        return s
    end
    api.writable_data=function(address,n) assert(address==now.address and n==8);return case~='readonly' end
    api.write=function(address,bytes)
        assert(address==now.address and #bytes==8)
        writes[#writes+1]=bytes
        mem=(case=='partial' and #writes==1) and bytes:sub(1,4)..mem:sub(5) or bytes
        return not(case=='partial' and #writes==1)
    end
    api.read=function(address,n)
        if address==now.address and n==8 then return mem end
        assert(address==0x1002e0 and n==4);return string.char(2,0,0,0)
    end
    local ok=pcall(patch.apply,api,0,0,t)
    if case=='success' or case=='remote' then assert(ok and #writes==1 and t.corrections==1)
    elseif case=='changed' or case=='mode_changed' or case=='remote_changed' or case=='remote_owner_changed' then assert(ok and #writes==0,case)
    elseif case=='readonly' then assert(not ok and #writes==0)
    else assert(not ok and #writes==2 and mem==now.original) end
end
patch.snapshot=original_snapshot
-- Archive startup enforces the external loader and preserves all update returns.
local function test_loader(loader,accepted)
    local install=assert(loadfile(source..'/archive_loader.lua'))()
    local checks=0
    local env=setmetatable({print=function()end,os={getenv=function()end},
        CowboyBingusModLoader=loader,update=function(a)return a,nil,3 end},{__index=_G})
    env._G=env
    setfenv(install,env)
    local previous=env.update
    local api={module=function(n)return n or 'exe'end,module_hash=function(n)return n end}
    install(function()return api end,{apply=function()checks=checks+1;return true,'waiting',false end},
        {revision='test',game_sha256='game.dll',exe_sha256='exe'})
    -- Idle (no reinforcement in progress): one check per frame.
    local a,b,c=env.update(4)
    assert(a==4 and b==nil and c==3 and checks==(accepted and 1 or 0))
    assert(select('#',env.update(4))==3)
    if accepted then
        -- While a reinforcement is in progress both update boundaries are checked.
        local before=checks
        env.ReinforcementBeaconFixData.previous={owned=true,mode=1,state=2}
        env.update(4)
        assert(checks==before+2)
        -- Not owned, outside gameplay modes or alive: the repeat is skipped again.
        for _,snapshot in ipairs({{owned=false,mode=1,state=2},{owned=true,mode=0,state=2},{owned=true,mode=1,state=3}}) do
            env.ReinforcementBeaconFixData.previous=snapshot
            before=checks;env.update(4);assert(checks==before+1)
        end
    end
    if not accepted then
        assert(env.update==previous and not env.ReinforcementBeaconFixData.active)
        assert(env.ReinforcementBeaconFixData.status:find('Bingus Shared Loader',1,true))
    end
end
for _,loader in ipairs({{api=1},{api=1,version=7},{api=2,version=7},{api=99,version=100}}) do
    test_loader(loader,true)
end
for _,loader in ipairs({false,{}, {api=0,version=100},{api='1',version=100}}) do test_loader(loader,false) end
print('PASS: beacon correction, three synthetic solo scenarios, guarded eight-byte writes, rollback, exclusions and minimum/newer loader API returns')
