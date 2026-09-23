local ffi=require('ffi')
local source,fixtures=assert(arg[1]),assert(arg[2])
local M=dofile(source..'/corpse_data.lua')
local captured=dofile(fixtures..'/stuck_impaler.lua')
captured=dofile(fixtures..'/layout_25327279.lua')(captured)
local api=dofile(source..'/windows_api.lua')()
api.read=function(pointer,size)
    local address=api.address(pointer)
    for _,block in ipairs(captured.blocks) do
        if address>=block[1] and address+size<=block[1]+#block[2] then
            local offset=address-block[1]
            return block[2]:sub(offset+1,offset+size)
        end
    end
end
api.time=function()return 0 end
api.clock=nil -- Correctness replay; wall-time scheduling has separate tests.
local game,exe=ffi.cast('uint8_t *',captured.game),ffi.cast('uint8_t *',captured.exe)
local state={};local units,status=M.snapshot(api,game,exe,state)
assert(status=='ready' and #units==1,tostring(state.last_skip or status))
local u=units[1]
assert(u.unit==captured.unit and u.main_enabled==15 and u.main_static==15)
assert(not u.owner and u.update_enabled)
local actions=M.plan(u)
local poses,claws,leg=0,0
for _,a in ipairs(actions) do
    if a.kind=='disable' then claws=claws+1 else poses=poses+1 end
    assert(a.actor.enabled and a.actor.stable and not a.actor.registered)
    if a.actor.id==0x9000609d then leg=a end
end
assert(claws==3 and poses>0 and leg and leg.gap>81 and leg.gap<83)
for _,a in ipairs(u.actors) do
    assert(a.id~=0x900060b7 and a.id~=0x900060b6 and a.id~=0x9000a1a2,
        'Recorded disabled/tagged tentacle bodies are excluded')
end
local pose_calls,disable_calls=0,0
state.native={pose=function()pose_calls=pose_calls+1 end,
    disable=function()disable_calls=disable_calls+1 end,stop_sync=function()error('No renewed motion in one frozen sample') end}
assert(M.apply(api,game,exe,state))
assert(pose_calls==poses and disable_calls==claws and state.accepted_units==1)
print(string.format('PASS: translated stuck Impaler fixture through production reader/planner/apply; %d collider repairs, %d claw disables, %.3f m leg gap; synthetic allocations/stub commands only',poses,claws,leg.gap))
