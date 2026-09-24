-- Only the owner-routed request policy is exercised; native calls are stubs.
local source=assert(arg[1])
local M=dofile(source..'/corpse_data.lua')
local original=M.snapshot
local function unit(resource)
    return {unit=99,id=77,resource=resource,settled=true,corpse=false,
        owner=false,active=true,update_enabled=false,main_enabled=M.profiles[resource].bodies,main_static=M.profiles[resource].bodies,
        main_signature='15 unchanged handles',actors={},guards={{address=1,bytes='identity'}},
        root_body={id=42,guards={{address=2,bytes='root'}}},manager=100,index=2}
end
for resource in pairs(M.profiles) do
    for _,variant in ipairs({'normal','stale','root_changed','replaced_entity','replaced_limb',
        'dynamic','inactive','resumed','not_settled','untracked','owner','request_error','disappeared'}) do
        local u=unit(resource)
        local now,requests,handoffs,stale,root_changed=100,0,0,false,false
        local api={time=function()return now end,read=function(address)
            if address==1 then return stale and 'changed' or 'identity' end
            if address==2 then return root_changed and 'changed' or 'root' end
        end}
        local state={fling_stopped={[u.unit]={entity=u.id,resource=u.resource,members=u.main_signature,
            stopped_at=100,last_scan=0}},native={
            request_completion=function(entity)
                assert(entity==77);requests=requests+1
                if variant=='request_error' then error('Simulated request failure') end
            end,
            stop_sync=function()handoffs=handoffs+1 end,
            pose=function()error('No pose changes')end,disable=function()error('No collider changes')end}}
        M.snapshot=function()return {u},'ready' end
        if variant=='untracked' then state.fling_stopped={} end
        for _,t in ipairs({100,100.5,100.999}) do now=t;M.apply(api,0,0,state) end
        assert(requests==0,'One-second grace period is required')
        if variant=='stale' then stale=true
        elseif variant=='root_changed' then root_changed=true
        elseif variant=='replaced_entity' then u.id=u.id+1
        elseif variant=='replaced_limb' then u.main_signature='new limb'
        elseif variant=='dynamic' then u.main_static=u.main_static-1
        elseif variant=='inactive' then u.active=false
        elseif variant=='resumed' then u.update_enabled=true;u.root_body.pose={}
        elseif variant=='not_settled' then u.settled=false
        elseif variant=='owner' then u.owner=true
        elseif variant=='disappeared' then M.snapshot=function()return {},'ready' end end
        now=101
        local ok=pcall(M.apply,api,0,0,state)
        assert(ok==(variant~='request_error'))
        local expected=(variant=='normal' or variant=='request_error') and 1 or 0
        assert(requests==expected and (state.completion_requests or 0)==expected)
        assert((state.completion_corpse_observed or 0)==0,'Request is not confirmation')
        for _,t in ipairs({105.1,106,107}) do now=t;M.apply(api,0,0,state) end
        assert(requests==expected,'Request cannot repeat, including after an exception')
        assert(handoffs==(variant=='owner' and 1 or 0),'Existing ownership handoff preserved')
        if variant=='normal' then
            assert(state.completion_pending==1)
            -- Native conversion replaces the entity, retaining the unit.
            u.id=u.id+5;u.corpse=true;u.main_signature=nil;now=108
            M.apply(api,0,0,state)
            assert(state.completion_corpse_observed==1 and state.completion_pending==0)
            now=109;M.apply(api,0,0,state)
            assert(state.completion_corpse_observed==1,'Observe conversion once')
        end
        M.snapshot=function()return {},'waiting_for_mission' end
        M.apply(api,0,0,state)
        assert(next(state.fling_stopped)==nil and state.completion_pending==0)
    end
end
M.snapshot=original
print('PASS: 21-profile completion grace, once-only requests, lifecycle, identity, ownership and mission exit')
