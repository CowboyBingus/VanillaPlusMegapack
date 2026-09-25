-- Small repeated realignments of one actor wait out a cooldown; the first
-- correction, large repeats and changed identities still apply immediately.
local source,fixtures=assert(arg[1]),assert(arg[2])
local ffi=require('ffi')
local M=dofile(source..'/corpse_data.lua')
local production=dofile(source..'/windows_api.lua')()
local api={address=production.address,distance=production.distance,pointer=production.pointer,
    read=function(at,size) return ffi.string(at,size) end}
local _,g,e,state,f=dofile(fixtures..'/perf_scene.lua')(M,api,0,0,1)
local body=f.bodies[f.units[1]][16]
local poses={}
state.native.pose=function(id) poses[#poses+1]=id end
local function poll(t)
    f.tick(t);local before=#poses
    assert(M.apply(api,g,e,state))
    return #poses-before
end
assert(poll(0)==0,'Aligned corpse needs no command')
-- The stub never moves the body, so an uncapped mod would re-pose every poll.
f.matrix(body,.05)
assert(poll(1)==1,'First small correction applies immediately')
local actor=poses[#poses]
assert(poll(1.1)==0 and poll(1.5)==0 and poll(1.9)==0,'Small repeats wait out the cooldown')
assert(state.reposes_deferred==3)
assert(poll(2.0)==1,'The cooldown expires after one second')
-- A large repeat is an obstruction again: no waiting.
f.matrix(body,2)
assert(poll(2.1)==1,'Large repeat applies immediately')
f.matrix(body,.05)
assert(poll(2.2)==0,'Small drift after a large correction waits again')
-- A rotation beyond five degrees also bypasses the cooldown.
local turned=ffi.new('float[16]',{math.cos(math.rad(8)),math.sin(math.rad(8)),0,0,
    -math.sin(math.rad(8)),math.cos(math.rad(8)),0,0,0,0,1,0,.05,0,0,1})
ffi.copy(body,turned,64)
assert(poll(2.3)==1,'Large rotation applies immediately')
-- A cooldown entry for another entity never holds this one.
state.reposed[actor].entity=state.reposed[actor].entity+1
f.matrix(body,.05)
assert(poll(2.4)==1,'Changed identity is not held')
-- Clock regression and mission exit both clear the cooldown.
assert(poll(2.5)==0)
assert(poll(1.0)==1,'A clock that goes backwards never holds a command')
ffi.cast('uint32_t *',f.mode+8)[0]=0
assert(poll(1.1)==0 and next(state.reposed)==nil,'Mission exit clears the cooldown')
ffi.cast('uint32_t *',f.mode+8)[0]=1
assert(poll(1.2)==1,'First correction of the next mission is immediate')
-- Entries expire, so the table stays bounded by recently corrected actors.
f.matrix(body,0)
assert(poll(3)==0 and next(state.reposed)==nil,'Expired entries are pruned')
print('PASS: repeat realignment cooldown, large-gap and rotation bypass, identity, clock, mission exit and pruning')
