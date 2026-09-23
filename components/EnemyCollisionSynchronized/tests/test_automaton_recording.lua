-- Captured actor/body/node bytes; synthetic containers; stubbed native commands.
local ffi=require('ffi')
local source,fixtures=assert(arg[1]),assert(arg[2])
local M=dofile(source..'/corpse_data.lua')
for _,name in ipairs({'automaton_static','automaton_mixed'}) do
    local captured=dofile(fixtures..'/'..name..'.lua')
    captured=dofile(fixtures..'/layout_25327279.lua')(captured)
    local api=dofile(source..'/windows_api.lua')()
    api.read=function(pointer,size)
        local address=api.address(pointer)
        for _,b in ipairs(captured.blocks) do
            if address>=b[1] and address+size<=b[1]+#b[2] then
                return b[2]:sub(address-b[1]+1,address-b[1]+size)
            end
        end
    end
    api.time=function()return 0 end
    api.clock=nil -- Correctness replay; wall-time scheduling has separate tests.
    local g,e=ffi.cast('uint8_t *',captured.game),ffi.cast('uint8_t *',captured.exe)
    local state={};local units,status=M.snapshot(api,g,e,state)
    assert(status=='ready' and #units==1,tostring(state.last_skip or status))
    local u=units[1];assert(u.unit==captured.unit and u.corpse and not u.owner)
    local actions=M.plan(u);local maxgap=0
    for _,action in ipairs(actions) do
        assert(action.kind=='pose' and action.actor.motion==0 and not action.actor.registered)
        maxgap=math.max(maxgap,action.gap)
    end
    if name=='automaton_mixed' then
        assert(u.main_enabled==10 and u.main_static==7)
        assert(#actions>0 and maxgap>.60 and maxgap<.61,
            'Recorded mixed Corpse must repair the displaced 60 cm auxiliary collider')
    else
        assert(u.main_enabled==15 and u.main_static==15 and maxgap>.52 and maxgap<.53)
    end
    local calls=0
    state.native={pose=function(id)
        for _,body in ipairs(u.main_bodies) do assert(id~=body.id,'Main bodies never posed') end
        calls=calls+1
    end,disable=function()error('No Automaton collision removal')end,
    stop_sync=function()error('Corpse physics must not be stopped')end,
    request_completion=function()error('Already a Corpse')end}
    assert(M.apply(api,g,e,state));assert(calls==#actions)
    if name=='automaton_mixed' then
        assert(state.mixed_corpse_realignments==calls)
        u.corpse=false;assert(#M.plan(u)==0,'Mixed RagdollSync remains excluded')
        u.corpse=true;u.main_dynamic_allowed=u.main_dynamic_allowed-1
        assert(#M.plan(u)==0,'An unapproved dynamic main body still blocks repair')
        u.main_dynamic_allowed=u.main_dynamic_allowed+1;u.main_enabled=u.main_enabled-1
        assert(#M.plan(u)==0,'Missing primary still blocks repair')
        local primary={};for _,b in ipairs(u.main_bodies) do primary[b.id]=true end
        local function u32(bytes,off)
            local value=ffi.new('uint32_t[1]');ffi.copy(value,bytes:sub(off+1),4);return tonumber(value[0])
        end
        local block
        for _,b in ipairs(captured.blocks) do
            if #b[2]==160 and primary[u32(b[2],144)] and u32(b[2],64)==0 then block=b;break end
        end
        assert(block);local saved=block[2]
        local function disturb()block[2]=saved:sub(1,64)..'\123\0\0\0'..saved:sub(69)end
        disturb();local changed=M.snapshot(api,g,e,{})
        assert(#changed==1 and #M.plan(changed[1])==0,'New dynamic core actor blocks actual reader/planner')
        block[2]=saved
        local snapshot=M.snapshot
        M.snapshot=function(a,g,e,s,consume,budget)
            return snapshot(a,g,e,s,function(u)disturb();consume(u)end,budget)
        end
        calls=0;M.apply(api,g,e,state);M.snapshot=snapshot;block[2]=saved
        assert(calls==0,'Changed primary state cancels pending auxiliary commands')
    end
    print(string.format('PASS: %s, %.3f m offset; auxiliary-only commands and unchanged main physics',name,maxgap))
end
