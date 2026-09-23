local source, fixture_path = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
ffi.cdef('int QueryPerformanceCounter(void *); int QueryPerformanceFrequency(void *);')
local kernel = ffi.load('kernel32')
local frequency, counter = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
assert(kernel.QueryPerformanceFrequency(frequency) ~= 0)
local hz = tonumber(frequency[0])
local function clock() kernel.QueryPerformanceCounter(counter); return tonumber(counter[0])/hz end
local M = dofile(source..'/corpse_data.lua')
local scene = dofile(fixture_path)
local api = dofile(source..'/windows_api.lua')()
api.clock = clock
local real_read = api.read
local calls, bytes = 0, 0
local counted_read = function(address,size) calls=calls+1;bytes=bytes+size;return real_read(address,size) end
api.read=counted_read
print('scene,living,ragdolls,corpses,mean_ms,p95_ms,max_ms,reads_per_poll,bytes_per_poll,units_per_poll')
for _, config in ipairs({{'empty',0,0,0},{'living',256,0,0},{'crowd',1500,0,0},
    {'settled',0,32,32},{'mixed',500,48,48}}) do
    collectgarbage('collect')
    local _,g,e,state,f = scene(M,api,config[2],config[3],config[4])
    api.read=counted_read;api.profiler=nil
    local profiler=arg[3]=='profile' and dofile(source..'/profiler.lua').new(api,'benchmark')
    api.profiler=profiler
    local function apply()
        if profiler then profiler.begin(state) end
        assert(M.apply(api,g,e,state))
        if profiler then profiler.finish(state) end
    end
    for i=1,10 do f.tick(i/30);apply() end
    local times,total,observed = {},0,0
    calls,bytes=0,0
    for i=11,110 do
        f.tick(i/30)
        local start=clock();apply();local elapsed=(clock()-start)*1000
        total=total+elapsed;times[#times+1]=elapsed;observed=observed+(state.observed or 0)
    end
    table.sort(times)
    print(string.format('%s,%d,%d,%d,%.4f,%.4f,%.4f,%.1f,%.1f,%.2f',config[1],config[2],config[3],config[4],
        total/#times,times[math.ceil(#times*.95)],times[#times],calls/#times,bytes/#times,observed/#times))
    if profiler and arg[4] then
        local file=assert(io.open(arg[4]..'/'..config[1]..'-profile.txt','w'));file:write(profiler.text(state));file:close()
    end
end
