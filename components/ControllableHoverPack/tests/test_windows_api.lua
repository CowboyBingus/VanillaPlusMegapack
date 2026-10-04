-- The runtime-backed Windows adapter in a fresh LuaJIT process: its contract,
-- private Windows names, protection checks and write limit, the module hash
-- once per session, and the real snapshot/settings modules on a synthetic game
-- layout in real memory, counting real protection queries.
local source=assert(arg[1])
local ffi=require('ffi')
-- Another mod loaded first and declared these names with other prototypes;
-- plain names in this mod would now bind to them.
ffi.cdef [[
    int GetModuleHandleA(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int GetModuleFileNameW(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int GetCurrentProcess(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int ReadProcessMemory(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int WriteProcessMemory(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int VirtualQuery(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int QueryPerformanceCounter(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int QueryPerformanceFrequency(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int CreateFileW(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int ReadFile(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int CloseHandle(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int BCryptOpenAlgorithmProvider(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int BCryptCloseAlgorithmProvider(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int BCryptCreateHash(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int BCryptHashData(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int BCryptFinishHash(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int BCryptDestroyHash(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int GetTickCount64(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int GetCurrentProcessId(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int GetForegroundWindow(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    int GetWindowThreadProcessId(int, int, int, int, int, int); /* -- lint-ok: R1 deliberate clash */
    void *hd2chpt_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int hd2chpt_VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *old) __asm__("VirtualProtect");
    uint64_t hd2chpt_GetTickCount64(void) __asm__("GetTickCount64");
]]
local kernel=ffi.load('kernel32')
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local create=assert(loadfile(source..'/windows_api.lua'))()
-- As the build passes it: a memory api of bingus_memory.lua extended by
-- bingus_write.lua, one per adapter.
local read_side,write_side=assert(loadfile(source..'/bingus_memory.lua'))(),assert(loadfile(source..'/bingus_write.lua'))()
local memory=write_side.extend(read_side.new(runtime))
local api,again=create(runtime,memory),create(runtime,write_side.extend(read_side.new(runtime)))
assert(not pcall(create,runtime) and not pcall(create,runtime,read_side.new(runtime)),'the adapter needs the read and write sides')
for _,name in ipairs({'time','module','module_hash','read','pointer','distance','address','writable_data','write','focused'})do
    assert(type(api[name])=='function' and type(again[name])=='function','adapter lacks '..name)
end
local function p(n)return ffi.string(ffi.new('uint64_t[1]',n),8)end
local page=ffi.cast('uint8_t *',kernel.hd2chpt_VirtualAlloc(nil,8192,0x3000,4));assert(page~=nil)
for i=0,255 do page[i]=i end
assert(api.read(page,4)=='\0\1\2\3' and api.read(ffi.cast('uint8_t *',1),8)==nil)
assert(api.writable_data(page,280) and not api.writable_data(page,281) and not api.writable_data(page,0))
assert(api.write(page+4095,'\18\52') and again.read(page+4095,2)=='\18\52','write across pages')
assert(not api.write(page,string.rep('x',281)) and page[0]==0,'a write above 280 bytes is refused')
-- checked: the caller verified the destination just before, so no query.
local queries=memory.queries
assert(api.write(page+8,'\7\7',true) and page[8]==7 and page[9]==7 and memory.queries==queries,'a checked write makes no query')
assert(not api.write(page,string.rep('x',281),true) and page[0]==0,'the 280-byte limit holds for a checked write')
local exe=api.module(nil);assert(exe~=nil and api.module('hd2chp_no_such_module.dll')==nil)
assert(not api.writable_data(exe,1) and not api.write(exe,'\0'),'module image refused')
assert(kernel.hd2chpt_VirtualProtect(page+4096,4096,2,ffi.new('uint32_t[1]'))~=0)
assert(not api.write(page+4096,'\1') and not api.write(page+4095,'\1\2'),'read-only page refused')
assert(api.pointer(p(0x12345678))==0x12345678 and api.pointer('xx'..p(0x10000),2)==0x10000,'pointers as numbers')
assert(api.pointer(p(0xffff))==nil and api.pointer(p(2^47))==nil and api.pointer(nil)==nil and api.pointer(p(0x10000),1)==nil)
assert(api.distance(page+16,page)==16 and api.address(page)==tonumber(ffi.cast('uintptr_t',page)))
assert(not pcall(api.address,ffi.cast('uint8_t *',1)),'address outside user space')
-- Plain-number addresses; buffer reads land in the caller's buffer.
local at=tonumber(ffi.cast('uintptr_t',page))
local buffer=ffi.new('uint8_t[16]');local into={data=buffer,address=tonumber(ffi.cast('uintptr_t',buffer)),size=16}
assert(api.read(at+1,3)=='\1\2\3' and api.read(at,4,into,2)==true and buffer[2]==0 and buffer[5]==3)
assert(api.read(at,4,into,13)==nil and api.read(1,8,into,0)==nil and api.read(at,0)==nil,'bad ranges and memory refused')
-- Buffer reads, the focus check and the clock allocate nothing, even
-- interpreted (after a first focus check has looked up its two functions).
api.focused()
jit.off();collectgarbage('collect');collectgarbage('stop') -- lint-ok: R4,R5 test only: counts garbage in the interpreter
local start=collectgarbage('count')
for _=1,100 do assert(api.read(at,8,into,0));api.focused();api.time()end
local bytes=(collectgarbage('count')-start)*1024
collectgarbage('restart');jit.on() -- lint-ok: R4,R5 test only: restores the collector and the JIT
assert(bytes==0,'buffer reads, focus checks and the clock: '..bytes..' bytes in 100')
-- The clock is the runtime's: seconds as a number, never going back, against
-- the tick count over about 200 ms, and no garbage compiled either (counted
-- in a window in which the JIT compiled nothing, since compiling allocates).
assert(api.time==memory.time,'the clock comes from the runtime')
do
    local ticks=tonumber(kernel.hd2chpt_GetTickCount64())
    local first=api.time();local last=first
    while tonumber(kernel.hd2chpt_GetTickCount64())-ticks<200 do
        local now=api.time();assert(type(now)=='number' and now>=last,'the clock went back');last=now
    end
    local elapsed,expected=api.time()-first,(tonumber(kernel.hd2chpt_GetTickCount64())-ticks)/1000
    assert(math.abs(elapsed-expected)<0.05,'the clock counts seconds: '..elapsed..' s against '..expected..' s')
    local compiling=0
    local function count(what)if what=='start' or what=='stop' then compiling=compiling+1 end end
    local function clock(n)local sum=0;for _=1,n do sum=sum+api.time()end;return sum end
    jit.attach(count,'trace') -- lint-ok: R5 test only: tells JIT work from the clock's garbage
    local compiled
    for _=1,50 do
        clock(1000)
        collectgarbage('collect');collectgarbage('stop') -- lint-ok: R4 test only: counts garbage with the collector stopped
        local before,events=collectgarbage('count'),compiling
        clock(10000)
        compiled=(collectgarbage('count')-before)*1024
        collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped
        if compiling==events then break end
        compiled=nil
    end
    jit.attach(count) -- lint-ok: R5 test only: detaches the handler above
    assert(compiled==0,'the clock, compiled: '..tostring(compiled)..' bytes in 10,000 calls')
end
local hash=api.module_hash(exe);assert(#hash==64 and hash:match('^[0-9A-F]+$'))
local hash_reads=BingusRuntime.hash_reads
assert(again.module_hash(exe)==hash and BingusRuntime.hash_reads==hash_reads,'module hash read once per session')
assert(type(api.focused())=='boolean')
print('PASS: runtime-backed adapter: private Windows names, reads (buffer reads and the focus check allocate nothing), the clock from the runtime in seconds (no garbage, interpreted or compiled), pointers as numbers, protection checks, 280-byte limit, module hash once per session')

-- The real modules on a synthetic layout in real memory (as test_snapshot.lua
-- and test_settings.lua), fixture addresses rebased into one reservation.
local LOW=0x10000000
local base=tonumber(ffi.cast('uintptr_t',kernel.hd2chpt_VirtualAlloc(nil,0x3a000000,0x2000,4)));assert(base~=0)
local function R(x)return base+(x-LOW)end
local committed={}
local function put(x,b)
    for n=math.floor(R(x)/4096),math.floor((R(x)+#b-1)/4096)do
        if not committed[n] then assert(kernel.hd2chpt_VirtualAlloc(ffi.cast('void *',n*4096),4096,0x1000,4)~=nil);committed[n]=true end
    end
    ffi.copy(ffi.cast('uint8_t *',R(x)),b,#b)
end
local function get(x,n)return ffi.string(ffi.cast('uint8_t *',R(x)),n)end
local function u(x)return ffi.string(ffi.new('uint32_t[1]',x),4)end
local function ptr(x)return p(R(x))end
local function f(x)return ffi.string(ffi.new('float[1]',x),4)end
local function hexbytes(h)return (h:gsub('..',function(x)return string.char(tonumber(x,16))end)):reverse()end
local function ent(a,h,id,unit)put(a,hexbytes(h)..u(id)..u(unit)..u(5)..u(1))end
local function map(a,data,key,index,empty,mult)
    put(a,ptr(data)..u(8)..u(empty)..u(mult))
    for i=0,7 do put(data+8*i,u(empty)..u(empty==0 and 0 or 0xffffffff))end
    if key then put(data+8*((key*mult)%8),u(key)..u(index))end
end
local G,mode,pm,em,am,eq,jm,attach=0x10000000,0x30000000,0x31000000,0x32000000,0x34000000,0x35000000,0x36000000,0x37000000
local D,RES,FORWARD=0x38000000,0x39000000,0x20010000
for rva,a in pairs({[0x33266a0]=mode,[0x3326468]=pm,[0x346bf98]=em,[0x3326d20]=am,[0x3326738]=eq,[0x3326bb8]=jm,[0x3326dc0]=attach})do put(G+rva,ptr(a))end
put(mode,string.rep('\0',0x44));put(mode+8,u(1));put(mode+0x40,u(2))
put(pm+0x84,u(2)..u(2));put(pm+0xe8,ptr(0x40000000));ent(0x40000000,'1111111111111111',10,99)
put(pm+0x3a8,u(391));map(em+0xf22ec8,0x20000000,391,2,0xffffffff,1)
local avatar=em+0xf32f18+48;ent(avatar,'4d1c334d294dfa97',513,391)
map(am+0xf8,0x20000100,513,1,0xffffffff,1);put(am+0x6c,u(2));put(am+0x118,ptr(avatar))
map(eq+40,0x20000200,513,1,0xffffffff,1);put(eq+64,ptr(0x41000000));put(0x41000008,ptr(avatar));put(eq+80,ptr(0x42000000));put(0x42000000+48+12,u(524))
map(jm+32,0x20000300,524,1,0xffffffff,1);put(jm+16,u(2)..u(2));put(jm+56,ptr(0x43000000));put(0x43000008,ptr(0x44000000))
ent(0x44000000,'5ec80f4f1cdb66cf',524,250)
map(attach+32,0x20000400,524,1,0xffffffff,1);put(attach+64,ptr(0x45000000));put(0x45000000+48+4,u(513))
local flags=am+0x53d900+0x1238+0xf80;put(flags,string.rep('\0',24));put(flags+8,u(4));put(flags+12,u(4))
put(jm+80,ptr(0x46000000));put(0x46000000,string.rep('\0',10))
local input=am+0x150+0xa7aec+0x1b68+15*32;put(input,string.rep('\0',32))
put(jm+4,u(32));put(jm+12,u(2));put(jm+152,u(0));put(jm+160,ptr(D))
map(jm+96,FORWARD,nil,nil,0,2);map(jm+128,0x20000500,nil,nil,0xffffffff,2)
put(em+0xf12cb8,ptr(RES));put(RES,string.rep('\0',96));put(RES,hexbytes('5ec80f4f1cdb66cf')..u(0)..u(0))
put(RES+96,string.rep('\0',153)..'\1'..'\1\1'..f(6)..string.rep('\0',120));put(D,string.rep('\0',560))
local patch=assert(loadfile(source..'/hover_data.lua'))()
patch.policy=assert(loadfile(source..'/cancel.lua'))();patch.settings=assert(loadfile(source..'/settings.lua'))()
api.focused=function()return true end
local game,state=ffi.cast('uint8_t *',R(G)),{}
local function frame(ps,held,expected)
    if ps then put(0x46000005,ps)end
    put(input+8,f(held))
    local before=memory.queries
    local ok,status=pcall(patch.apply,api,game,nil,state)
    assert(ok==(expected~=false),tostring(status))
    if expected then assert(status==expected,expected..' expected, got '..tostring(status))end
    return memory.queries-before
end
local IDLE,FLIGHT,LANDING='\0\0\1\0\0','\1\0\1\0\1','\1\1\1\0\1'
local function duration()return ffi.cast('float *',ffi.cast('uint8_t *',R(D+156)))[0]end
local function press()
    assert(frame(FLIGHT,.3,'watching_hover')==0 and frame(nil,0,'watching_hover')==0)
    return frame(nil,.01,'cancel_requested')
end
assert(frame(IDLE,0,'waiting_for_hover')==0)
assert(press()==5,'first cancel: one protection query per written destination')
assert(duration()==1/1024 and state.lease)
assert(frame(LANDING,0,'native_descent')==0)
assert(frame(IDLE,0,'waiting_for_hover')==1 and duration()==6 and not state.lease)
assert(press()==1 and duration()==1/1024,'a reused override needs one query')
assert(frame(IDLE,0,'waiting_for_hover')==1 and duration()==6)
-- Forget the override; a read-only forward map makes the next creation fail
-- its last destination check: nothing is written, so nothing is undone.
map(jm+96,FORWARD,nil,nil,0,2);map(jm+128,0x20000500,nil,nil,0xffffffff,2);put(jm+152,u(0));put(D,string.rep('\0',280))
local before=get(D,280)..get(0x20000500,64)..get(jm+152,4)..get(FORWARD,64)
assert(kernel.hd2chpt_VirtualProtect(ffi.cast('void *',R(FORWARD)),4096,2,ffi.new('uint32_t[1]'))~=0)
assert(frame(FLIGHT,.3,'watching_hover')==0 and frame(nil,0,'watching_hover')==0)
assert(frame(nil,.01,false)==4,'all four destinations checked before the first write')
assert(get(D,280)..get(0x20000500,64)..get(jm+152,4)..get(FORWARD,64)==before and not state.lease,'refused creation wrote nothing')
print('PASS: real modules on real memory: no query while idle, 5 on the first cancel, 1 per reuse and restore, a refused destination writes nothing')
