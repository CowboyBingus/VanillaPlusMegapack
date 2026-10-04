-- Snapshot metadata may be decoded once, but no cache may survive a poll.
local source,fixtures=assert(arg[1]),assert(arg[2])
local ffi=require('ffi')
local M=assert(loadfile(source..'/corpse_data.lua'))(dofile(source..'/corpse_profiles.lua'))
local production=dofile(source..'/windows_api.lua')()
local calls=0
local api={address=production.address,distance=production.distance,
    pointer=function(...)calls=calls+1;return production.pointer(...)end,
    read=function(at,size)return ffi.string(type(at)=='number' and ffi.cast('uint8_t *',at) or at,size)end}
local _,g,e,state,f=dofile(fixtures..'/perf_scene.lua')(M,api,0,0,1)
assert(M.apply(api,g,e,state));assert(state.observed==1 and not state.realignments)
assert(calls<32,'One unit repeatedly decodes the same world/pool metadata: '..calls)
local first=calls
-- Moving an auxiliary body is still detected immediately on the next poll.
f.matrix(f.bodies[f.units[1]][16],2)
assert(M.apply(api,g,e,state));assert(state.realignments==1)
assert(calls-first<32,'Metadata cache must work on repair polls too')
-- The next poll must see changed world getter metadata, before any command.
local world=ffi.cast('uint8_t **',e+0x27ba8a8+176*2)[0]
local vt=ffi.cast('uint8_t **',world)[0]
ffi.cast('uint8_t **',vt+136)[0]=e+0xd11661
local before=state.realignments
assert(not pcall(M.apply,api,g,e,state))
assert(state.getter_failures==1 and state.realignments==before,'Stale world metadata authorized a command')
ffi.cast('uint8_t **',vt+136)[0]=e+0xd0cfa0
-- A changed actor pool must also be reloaded, with no stale actor commands.
f.u(e+0x2369b00+64*21+36,0)
assert(M.apply(api,g,e,state))
assert(state.observed==0 and state.realignments==before,'Stale actor-pool metadata authorized a command')
print('PASS: bounded pointer decoding, immediate next-poll realignment, world/pool invalidation and unchanged mutation guards')
