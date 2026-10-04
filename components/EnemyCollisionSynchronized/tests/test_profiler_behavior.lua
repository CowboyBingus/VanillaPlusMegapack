-- Deterministic native-layout replay with telemetry on/off. Every game read,
-- native call and gameplay counter must agree, including renewed root motion.
local source,fixtures=assert(arg[1]),assert(arg[2])
local ffi=require('ffi')
local scene=dofile(fixtures..'/perf_scene.lua')
local M=assert(loadfile(source..'/corpse_data.lua'))(dofile(source..'/corpse_profiles.lua'))
local production=dofile(source..'/windows_api.lua')()
local ticks,reads=0,0
local api={pointer=production.pointer,address=production.address,distance=production.distance}
local function read(at,size)reads=reads+1;ticks=ticks+.0000001;return ffi.string(type(at)=='number' and ffi.cast('uint8_t *',at) or at,size)end
local _,g,e,initial,f=scene(M,api,300,3,3)
api.clock=function()return api.time()+ticks end
local saved={}
for i,storage in ipairs(f.owners)do saved[i]=ffi.string(storage,ffi.sizeof(storage))end
local function replay(profiled,source_override)
    -- A baseline from before the allowlist moved to corpse_profiles.lua loads as one file.
    local function load_sources(dir)
        local profiles=io.open(dir..'/corpse_profiles.lua')
        if not profiles then return dofile(dir..'/corpse_data.lua') end
        profiles:close();return assert(loadfile(dir..'/corpse_data.lua'))(dofile(dir..'/corpse_profiles.lua'))
    end
    local M=source_override and load_sources(source_override) or M
    -- Reuse identical addresses: separately allocated scenes can change guard
    -- batching distances and therefore their legitimate read counts.
    for i,storage in ipairs(f.owners)do ffi.copy(storage,saved[i],#saved[i])end
    ticks,reads=0,0;api.read=read;api.profiler=nil
    local state={native={}}
    local trace={}
    for _,method in ipairs({'pose','disable','stop_sync','request_completion'})do
        local previous=initial.native[method]
        state.native[method]=function(a,b,c)
            local id=method=='stop_sync' and b or a
            trace[#trace+1]=method..':'..tostring(id)
            if method=='pose' then
                for _,value in ipairs(b)do trace[#trace+1]=tostring(value)end
                for _,value in ipairs(c)do trace[#trace+1]=tostring(value)end
            end
            return previous(a,b,c)
        end
    end
    local profiler=profiled and dofile(source..'/profiler.lua').new(api,'test')
    api.profiler=profiler
    for i=1,360 do
        f.tick(i/30)
        if i==160 then
            for _,unit in ipairs(f.units)do
                for _,body in ipairs(f.bodies[unit])do f.matrix(body,2)end
            end
        end
        if profiler then profiler.begin(state)end
        assert(M.apply(api,g,e,state))
        if profiler then profiler.finish(state)end
    end
    assert(state.realignments>0 and state.fling_stops==3 and state.fling_stops_verified==3)
    assert(state.completion_requests==3,'Exercise completion as well as containment')
    local result={table.concat(trace,','),'reads='..reads}
    for _,key in ipairs({'observed','accepted_units','scan_entities','deep_inspections','budget_yields',
        'realignments','fling_stops','fling_stops_verified','completion_requests','skipped','history_expirations'})do
        result[#result+1]=key..'='..tostring(state[key])
    end
    if profiler then
        local report=profiler.text(state)
        for _,kind in ipairs({'ragdoll_settled','ragdoll_stopped','corpse_aligned','corpse_repair'})do
            assert(report:find('lifecycle='..kind,1,true),'Missing lifecycle '..kind)
        end
        assert(profiler.details.bodies.reads>0 and profiler.details.skeleton.reads>0)
    end
    f.u(f.mode+8,0)
    if profiler then profiler.begin(state)end
    assert(M.apply(api,g,e,state))
    if profiler then profiler.finish(state);assert(next(profiler.revisits)==nil)end
    assert(next(state.fling_history)==nil and next(state.fling_stopped)==nil)
    return table.concat(result,'\n')
end
local plain=replay(false)
collectgarbage('collect')
local measured=replay(true)
if measured~=plain then
    local a,b={},{}
    for line in plain:gmatch('[^\n]+')do a[#a+1]=line end
    for line in measured:gmatch('[^\n]+')do b[#b+1]=line end
    for i,line in ipairs(a)do if line~=b[i]then print('Difference '..i..': '..line:sub(1,200)..' / '..tostring(b[i]):sub(1,200))end end
end
assert(measured==plain,'Profiling changed game reads, native commands or gameplay counters')
if arg[3] then
    collectgarbage('collect')
    assert(replay(false,arg[3])==plain,'Optimization changed reads, native commands or gameplay counters versus baseline')
    print('PASS: optimized and baseline deterministic replays have identical game reads, commands and gameplay counters')
end
print('PASS: profiling preserves reads, repair poses, verified stops, completion requests, scheduling and mission cleanup')
