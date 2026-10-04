-- The Windows api (read_api.lua + platform.lua) in this process: reads into
-- caller buffers, the clock and memory telemetry allocate nothing, interpreted
-- or compiled, bad ranges and unreadable memory are refused, and the clock and
-- telemetry give the values the 64-bit calls give.
local root=assert(arg[1]);local ffi=require('ffi')
local api=dofile(root..'/src/platform.lua')(dofile(root..'/src/read_api.lua'))
local source=ffi.new('uint8_t[64]')
for i=0,63 do source[i]=i end
local at=tonumber(ffi.cast('uintptr_t',source))
local data=ffi.new('uint8_t[32]')
local into={data=data,address=tonumber(ffi.cast('uintptr_t',data)),size=32}
assert(api.read(at+8,16,into,8)==true and data[8]==8 and data[23]==23 and data[24]==0 and data[7]==0)
assert(api.read(at,16,into,17)==nil and api.read(at,0,into,0)==nil and api.read(at,4,into,-1)==nil,'Range outside the buffer')
assert(api.read(0x10,4,into,0)==nil,'Unreadable memory')
assert(api.read(ffi.cast('uint8_t *',source),4,into,0)==nil,'Buffer reads take number addresses')
assert(api.read(ffi.cast('uint8_t *',source)+4,4)=='\4\5\6\7','String reads are unchanged')
-- Reference calls under private names, like the mod's own.
ffi.cdef[[
    uint64_t hd2apc_test_GetTickCount64(void) __asm__("GetTickCount64");
    int hd2apc_test_GlobalMemoryStatusEx(void *status) __asm__("GlobalMemoryStatusEx");
]]
local kernel=ffi.load('kernel32')
-- The clock follows GetTickCount64 (the low word from GetTickCount).
local t=api.time();local reference=tonumber(kernel.hd2apc_test_GetTickCount64())/1000
assert(math.abs(t-reference)<0.1 and api.time()>=t,'Clock value')
-- Telemetry matches the 64-bit fields read directly; available memory moves
-- between the two calls, so within 256 MiB (a wrong high word is 4 GiB off).
local free,private,commit=api.memory()
local status=ffi.new('uint64_t[8]');ffi.cast('uint32_t *',status)[0]=64
assert(kernel.hd2apc_test_GlobalMemoryStatusEx(status)~=0)
assert(free>0 and private>0 and commit>0 and free%1==0 and commit%1==0)
assert(math.abs(free-tonumber(status[2]))<2^28 and math.abs(commit-tonumber(status[4]))<2^28,'Telemetry fields')
local function poll()assert(api.read(at,32,into,0));api.time();api.memory()end
local function garbage(n)
    collectgarbage('collect');collectgarbage('stop')
    local before=collectgarbage('count')
    for _=1,n do poll()end
    local bytes=(collectgarbage('count')-before)*1024
    collectgarbage('restart')
    return bytes
end
jit.off()
for _=1,30 do poll()end
local interpreted=garbage(1000)
-- Compiled: after a warm-up (traces compile there), the median of ten windows.
jit.on()
for _=1,1000 do poll()end
local windows={}
for i=1,10 do windows[i]=garbage(100)end
table.sort(windows)
assert(interpreted==0,interpreted..' bytes of garbage in 1000 interpreted reads, clock and memory polls')
assert(windows[6]==0,'Compiled: median '..windows[6]..' bytes of garbage in 100 reads, clock and memory polls')
print('PASS: Windows reads into caller buffers, the clock and memory telemetry allocate nothing, interpreted or compiled; bad ranges, unreadable memory and pointer addresses are refused; clock matches GetTickCount64 and telemetry the 64-bit fields')
