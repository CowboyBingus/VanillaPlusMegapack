local source=assert(arg[1])
local ffi=require('ffi')
local H=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'hostile_vm.lua')
-- Another mod loaded first and declared every Windows name the adapter and the
-- runtime bind, with other prototypes. ffi.cdef keeps the first one, so the
-- adapter and the runtime must use private names. None of these declarations
-- is ever called.
do
    local names={'GetTickCount64','GetModuleHandleA','GetModuleFileNameW','GetCurrentProcess','ReadProcessMemory',
        'WriteProcessMemory','VirtualQuery','QueryPerformanceCounter','QueryPerformanceFrequency','CreateFileW',
        'ReadFile','CloseHandle','BCryptOpenAlgorithmProvider','BCryptCloseAlgorithmProvider','BCryptCreateHash',
        'BCryptHashData','BCryptFinishHash','BCryptDestroyHash'}
    local status=H.clash(names)
    for _,name in ipairs(names) do assert(status[name]=='clashed',name..': '..tostring(status[name])) end
end
-- As in the build: the runtime's core runs once, and the adapter gets the read
-- side extended by the write side.
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local function new_memory()
    return assert(loadfile(source..'/bingus_write.lua'))().extend(assert(loadfile(source..'/bingus_memory.lua'))().new(runtime))
end
local create=assert(loadfile(source..'/windows_api.lua'))()
local api_memory=new_memory()
local api=create(runtime,api_memory)
-- Repeated initialization, with second copies of the runtime files, shares
-- declarations in the loader's Lua VM.
local again_memory=new_memory()
local again=create(runtime,again_memory)
assert(not pcall(create,runtime,assert(loadfile(source..'/bingus_memory.lua'))().new(runtime)),
    'the adapter needs the write side')
-- The clock is the runtime's time(): seconds as a Lua number, never going
-- back, and no allocation per call, interpreted or compiled (the adapter's own
-- 64-bit tick count allocated 16 bytes per interpreted call).
do
    assert(api.time==api_memory.time and again.time==again_memory.time,'the clock is the runtime time()')
    ffi.cdef [[ uint64_t sar_test_GetTickCount64(void) __asm__("GetTickCount64"); ]]
    local system=ffi.load('kernel32')
    local function ticks()return tonumber(system.sar_test_GetTickCount64())end
    local t0,s0=ticks(),api.time()
    repeat until ticks()-t0>=250
    local t1,s1,s2=ticks(),api.time(),again.time()
    assert(type(s0)=='number' and s1>=s0 and s2>=s1,'time() never goes back')
    assert(math.abs((s1-s0)-(t1-t0)/1000)<0.05,'time() counts seconds: '..(s1-s0)..' s over '..(t1-t0)..' ms')
    local flush,sink=H.jit_churn(),0
    local function loop(n)for _=1,n do sink=sink+api.time()end end
    -- Bytes per call: the median of three windows after a warm-up.
    local function per_call(compiled)
        flush()
        if not compiled then jit.off() end -- lint-ok: R5 test only: measures the interpreted case
        loop(1000);loop(1000)
        local windows={}
        for i=1,3 do windows[i]=H.heap_peak(loop,10000)*1024/10000 end
        jit.on() -- lint-ok: R5 test only: restores the JIT
        table.sort(windows);return windows[2]
    end
    local compiled,interpreted=per_call(true),per_call(false)
    assert(compiled==0 and interpreted==0,'time() allocated '..compiled..' B compiled, '..interpreted..' B interpreted per call')
    print('PASS: the clock is the runtime time(): seconds, never going back, 0 B per call compiled and interpreted')
end
-- A module's SHA-256 is read once per session for every mod.
do
    local exe=api.module(nil);local reads=rawget(_G,'BingusRuntime') and BingusRuntime.hash_reads or 0
    local hash=api.module_hash(exe)
    assert(#hash==64 and hash:find('^[0-9A-F]+$'),'uppercase SHA-256')
    assert(again.module_hash(exe)==hash and BingusRuntime.hash_reads==reads+1,'hash read once per session')
    -- The loader's build check is the runtime's verify_build, which takes the
    -- same session hashes. This process has no game.dll: it refuses before
    -- reading any module file.
    assert(api.verify_build==api_memory.verify_build and again.verify_build==again_memory.verify_build)
    local ok,why=api.verify_build({exe_sha256=hash,game_sha256=hash})
    assert(ok==false and why=='game modules unavailable' and BingusRuntime.hash_reads==reads+1,tostring(why))
end
ffi.cdef [[
    void *VirtualAlloc(void *address, size_t size, uint32_t allocation, uint32_t protection);
    int VirtualFree(void *address, size_t size, uint32_t operation);
    int VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *previous);
]]
local kernel=ffi.load('kernel32')
local allocation=kernel.VirtualAlloc(nil,8192,0x3000,4)
assert(allocation~=nil)
local data=ffi.cast('uint8_t *',allocation)
for _,pair in ipairs({{api,api_memory},{again,again_memory}}) do
    local a,m=pair[1],pair[2]
    assert(a.writable_data(data,8192))
    -- An unchecked write queries its range once (one region here) right before writing.
    local queries=m.queries
    assert(a.write(data+4095,'\x12\x34') and m.queries==queries+1)
    assert(a.read(data+4095,2)=='\x12\x34')
    -- checked: writable_data verified this range above; the write skips its own query.
    assert(a.write(data+4100,'\x56',true) and a.read(data+4100,1)=='\x56' and m.queries==queries+1)
    assert(not a.write(a.module(nil),'\0'))
end

-- The live fence had a static body in native filter 0x04a8fbf9 (destructible),
-- 11.286 m along a 29.736 m ray. Ordinary collision was not proof of a blocked shot.
do
    local function point(x,y,z)return ffi.string(ffi.new('float[3]',{x,y,z}),12)end
    local origin,target=point(0,0,2),point(0,29.736,2)
    local hits={{distance=11.286,unit=500,actor=200},{distance=14,unit=501,actor=201}}
    local filters={[200]=0x04a8fbf9,[201]=0x04a8fbf9,[300]=0xa0d00a12}
    local calls={}
    local function scene(_,_,_,length,collection,actors,filter,flags,ignore,out,capacity)
        assert(actors==3 and filter==0x393d9518 and flags==0x80000009 and ignore==123)
        assert(ffi.sizeof(out)==44*capacity)
        calls[#calls+1]=collection
        local included={}
        for _,h in ipairs(hits)do if h.distance<=length then included[#included+1]=h end end
        table.sort(included,function(a,b)return a.distance<b.distance end)
        local count=collection==1 and math.min(1,#included) or #included
        assert((collection==1 and capacity==1) or (collection==2 and capacity==32))
        for i=1,math.min(count,capacity)do
            local hit=included[i];local base=11*(i-1)
            ffi.cast('float *',out)[base+6]=hit.distance
            out[base+7]=hit.unit;out[base+8]=hit.actor
        end
        return count
    end
    local function classify(actor)return filters[actor]end
    local blocked,detail=api.cast_terrain(scene,2,123,origin,target,456,classify)
    assert(blocked==false and detail.reason=='destructible_cover' and #calls==2)
    -- A solid body in the same unit as the fence must still be checked.
    hits[#hits+1]={distance=25,unit=500,actor=300}
    blocked,detail=api.cast_terrain(scene,2,123,origin,target,456,classify)
    assert(blocked==true and detail.distance==25 and detail.reason=='static_obstruction')
    -- Solid cover in front of the fence needs only the ordinary closest query.
    hits[#hits].distance=5;calls={}
    assert(api.cast_terrain(scene,2,123,origin,target,456,classify)==true and #calls==1)
    hits[#hits]=nil
    -- Unknown/recycled actors cannot receive an unverified cover exemption.
    assert(api.cast_terrain(scene,2,123,origin,target,456,function()return nil end)==true)
    -- More cover than the bounded result buffer can hold is left to native
    -- ballistics; it must neither overrun the buffer nor create a false lock.
    hits={}
    for i=1,33 do hits[i]={distance=i*.5,unit=500,actor=200} end
    blocked,detail=api.cast_terrain(scene,2,123,origin,target,456,classify)
    assert(blocked==false and detail.reason=='cover_query_limit')
    print('PASS: destructible fences permit firing; solid terrain beyond cover, same-unit bodies and bounded overflow')
end

-- Actor ownership and filter names use the captured pool/body layout with
-- synthetic addresses and remapped handles. No native function is called.
do
    local actual_read=api.read;local memory={}
    local function put(a,b)for i=1,#b do memory[a+i-1]=b:sub(i,i)end end
    local function zero(a,n)put(a,string.rep('\0',n))end
    local function value(a,kind,n)put(a,ffi.string(ffi.new(kind..'[1]',n),ffi.sizeof(kind)))end
    local function uint(a,n)value(a,'uint32_t',n)end
    local function ptr(a,n)value(a,'uint64_t',n)end
    local exe=0x100000;local actor=0x80020001;local unit=0x40000a
    local pool=exe+0x2369b00+64*20;zero(pool,56)
    ptr(pool,0x200000);uint(pool+28,56);uint(pool+36,2);uint(pool+40,0x1ffff);uint(pool+52,0x20000)
    local entry=0x200000+56;zero(entry,40);uint(entry,actor);uint(entry+12,unit);uint(entry+20,1)
    ptr(exe+0x27ba8a8+176*2,0x300000);ptr(0x300018,0x400000)
    local body=0x400000+160;zero(body,160);uint(body+68,1);uint(body+108,14)
    uint(body+144,actor);uint(body+148,unit)
    ptr(exe+0x27c5e48,0x500000);uint(0x500000+248,103);ptr(0x500000+256,0x600000)
    uint(0x600000+4*14,0x04a8fbf9);uint(0x600000+4*55,0xa0d00a12)
    api.read=function(address,size)
        local a=tonumber(ffi.cast('uintptr_t',address));local b={}
        for i=0,size-1 do if not memory[a+i]then return nil end;b[#b+1]=memory[a+i]end
        return table.concat(b)
    end
    local base=ffi.cast('uint8_t *',exe)
    assert(api.actor_filter(base,actor,unit)==0x04a8fbf9)
    uint(body+108,55);assert(api.actor_filter(base,actor,unit)==0xa0d00a12);uint(body+108,14)
    assert(api.actor_filter(base,actor,unit+1)==nil)
    uint(entry,actor+1);assert(api.actor_filter(base,actor,unit)==nil);uint(entry,actor)
    uint(body+144,actor+1);assert(api.actor_filter(base,actor,unit)==nil);uint(body+144,actor)
    uint(0x500000+248,14);assert(api.actor_filter(base,actor,unit)==nil);uint(0x500000+248,103)
    local read=api.read;local reads=0
    api.read=function(address,size)
        local b=read(address,size)
        if tonumber(ffi.cast('uintptr_t',address))==entry and size==4 then
            reads=reads+1;if reads==2 then return string.rep('\0',4)end
        end
        return b
    end
    assert(api.actor_filter(base,actor,unit)==nil)
    api.read=actual_read
    print('PASS: native destructible filter lookup, solid terrain, invalid/recycled actors and read-time ownership changes')
end
local previous=ffi.new('uint32_t[1]')
for _,protection in ipairs({2,0x20,0x40}) do
    assert(kernel.VirtualProtect(data+4096,4096,protection,previous)~=0)
    for _,a in ipairs({api,again}) do
        assert(not a.writable_data(data,8192))
        assert(not a.write(data+4095,'\x56\x78'))
        assert(a.read(data+4095,2)=='\x12\x34')
    end
end
assert(kernel.VirtualFree(data,0,0x8000)~=0)
assert(not api.writable_data(data,1) and not api.write(data,'\0'))
print('PASS: Windows adapter repeated initialization, writable data and guarded memory rejection after another mod declared every Windows name it binds')

-- Exercise the engine-layout reader against synthetic data. No game code is
-- invoked: pose resolution uses only guarded reads through the adapter.
do
    local actual_read,actual_read_into=api.read,api.read_into;local memory={};local unit=0x400001
    local function scalar(kind,v)return ffi.string(ffi.new(kind..'[1]',v),ffi.sizeof(kind))end
    local function ptr(address,v)memory[address]=scalar('uint64_t',v)end
    local function uint(address,v)memory[address]=scalar('uint32_t',v)end
    -- Words and the job table are read into reused buffers through read_into.
    api.read_into=function(address,size,buffer)
        local b=api.read(address,size);if not b then return false end
        ffi.copy(buffer,b,size);return true
    end
    ptr(0x200000+0x1a100f0,0x300000);uint(0x300098,2)
    ptr(0x3000a0,0x400000);memory[0x400001]='\1'
    ptr(0x300088,0x500000);ptr(0x500008,0x600000)
    uint(0x600008,unit);uint(0x600070,2);ptr(0x600000,0x700000)
    ptr(0x7000e8,0x800000);memory[0x800000]='\x48\x8d\x41\x60\xc3'
    ptr(0x600088,0x900000);memory[0x900040]=string.rep('m',64)
    api.read=function(address,size)
        local b=memory[tonumber(ffi.cast('uintptr_t',address))]
        if b and #b==size then return b end
    end
    local binding=api.bind(ffi.cast('uint8_t *',0x100000),ffi.cast('uint8_t *',0x200000))
    assert(binding.pose(unit,1)==memory[0x900040])
    assert(not pcall(binding.pose,unit,2))
    memory[0x400001]='\2';assert(not pcall(binding.pose,unit,1));memory[0x400001]='\1'
    uint(0x600008,unit+1);assert(not pcall(binding.pose,unit,1));uint(0x600008,unit)
    -- The pose code is checked when a unit's path is located: a binding that
    -- already holds the path keeps it, a new path is refused.
    memory[0x800000]='wrong';assert(binding.pose(unit,1)==memory[0x900040])
    local fresh=api.bind(ffi.cast('uint8_t *',0x100000),ffi.cast('uint8_t *',0x200000))
    assert(not pcall(fresh.pose,unit,1));memory[0x800000]='\x48\x8d\x41\x60\xc3'
    -- A cached path is followed again when the unit's slot names another object.
    ptr(0x500008,0x610000);uint(0x610008,unit);uint(0x610070,2);ptr(0x610000,0x700000)
    ptr(0x610088,0x910000);memory[0x910040]=string.rep('n',64)
    assert(binding.pose(unit,1)==memory[0x910040]);ptr(0x500008,0x600000)
    assert(binding.pose(unit,1)==memory[0x900040])
    ptr(0x100000+0x347d7e0,0xa00000);ptr(0x100000+0x346bfa0,0xb00000)
    uint(0xa00000,1)
    assert(binding.terrain_path(unit,string.rep('\0',12),string.rep('\0',12))==nil)
    uint(0xa00000,0)
    local jobs=ffi.new('uint32_t[72]')
    for i=0,23 do jobs[3*i+2]=1 end
    for i=0,23 do
        jobs[3*i+2]=0;memory[0xa40008]=ffi.string(jobs,288)
        assert(binding.terrain_path(unit,string.rep('\0',12),string.rep('\0',12))==nil)
        jobs[3*i+2]=1
    end
    api.read,api.read_into=actual_read,actual_read_into
    print('PASS: muzzle pose identity and bounds; pending queries and each of 24 busy workers prevent native casts')
end

-- Declarations are made once per game and api.bind casts to named
-- function-pointer types: creating the adapter again or binding again adds no
-- C types to the table every mod in the VM shares and LuaJIT never frees.
-- (Function-pointer type strings added 35 per bind.)
do
    -- The next free ID: a probe struct takes two type IDs.
    local function next_type() return tonumber(ffi.typeof('struct { int probe; }')) end -- lint-ok: R2 the probe adds its two types on purpose
    local game,exe=ffi.cast('uint8_t *',0x100000),ffi.cast('uint8_t *',0x200000)
    api.bind(game,exe)
    local first=next_type()
    for _=1,5 do assert(loadfile(source..'/windows_api.lua'))()(runtime,new_memory()).bind(game,exe) end
    for _=1,5 do api.bind(game,exe) end
    local added=next_type()-first-2
    assert(added==0,'5 adapter creations and 10 binds added '..added..' C types')
    print('PASS: repeated adapter creations and binds add no C types')
end

-- A plane at z=0 models terrain independently of the gate implementation.
-- Living crawlers above the plane are reachable even with a downward barrel.
do
    local calls=0
    local function point(x,y,z)return ffi.string(ffi.new('float[3]',{x,y,z}),12)end
    local function plane(world,from,dir,length,collection,actors,filter,flags,ignore,out,capacity)
        calls=calls+1
        assert(world==2 and collection==1 and actors==3 and filter==0x393d9518 and flags==0x80000009)
        assert(ignore==123 and capacity==1 and ffi.sizeof(out)==44)
        assert(math.abs(dir[0]^2+dir[1]^2+dir[2]^2-1)<0.00001)
        local distance=-from[2]/dir[2]
        if dir[2]>=0 or distance<0 or distance>length then return 0 end
        ffi.cast('float *',out)[6]=distance;return 1
    end
    local origin=point(0,0,1.5)
    for _,distance in ipairs({2,20,80}) do
        assert(api.cast_terrain(plane,2,123,origin,point(0,distance,0.2))==false)
        assert(api.cast_terrain(plane,2,123,origin,point(0,distance,-0.8))==true)
        assert(api.cast_terrain(plane,2,123,origin,point(0,distance,0))==false)
    end
    assert(api.cast_terrain(plane,2,123,origin,point(0,20,4))==false)
    local before=calls
    assert(not pcall(api.cast_terrain,plane,2,123,origin,point(0,20,0/0)))
    assert(not pcall(api.cast_terrain,plane,2,123,origin,point(0,3000,0)))
    assert(calls==before)
    assert(not pcall(api.cast_terrain,function(_,_,_,_,_,_,_,_,_,out)
        ffi.cast('float *',out)[6]=0/0;return 1
    end,2,123,origin,point(0,20,-1)))
    -- Regression: an enemy's collision surface is in front of its aim node.
    -- Distance alone incorrectly kept live, aligned targets in no-fire mode.
    local function body(_,_,_,length,_,_,_,_,_,out)
        ffi.cast('float *',out)[6]=length-0.5
        out[7]=456;return 1
    end
    local blocked,detail=api.cast_terrain(body,2,123,origin,point(0,20,.2),456)
    assert(blocked==false and detail.reason=='target_surface' and detail.hit_unit==456)
    blocked,detail=api.cast_terrain(body,2,123,origin,point(0,20,.2),789)
    assert(blocked==true and detail.reason=='static_obstruction')
    blocked,detail=api.cast_terrain(plane,2,123,origin,point(0,20,-.8),456)
    assert(blocked==true and detail.hit_unit==0)
    print('PASS: exposed crawlers, buried targets, endpoint tolerance, native query arguments and invalid results')
    print('PASS: selected enemy surface permits fire; different obstruction or terrain still pauses')
end

-- Captured blockers were non-static character/ragdoll bodies, including a
-- zero-distance overlap and another body 6.342 m along a 22.243 m target ray.
-- Model the native actor-class predicate while selecting the closest hit.
do
    local function point(x,y,z)return ffi.string(ffi.new('float[3]',{x,y,z}),12)end
    local origin,target=point(0,0,2),point(0,22.243,2)
    local hits={
        {distance=0,flags=6,unit=200},
        {distance=6.342,flags=14,unit=201},
        {distance=6.4,flags=8322,unit=201},
        {distance=6.5,flags=131330,unit=201},
    }
    local function scene(_,_,_,length,_,actors,_,_,_,out)
        local closest
        for _,hit in ipairs(hits) do
            local admitted=actors==5 or (actors==3 and hit.flags%2==1)
            if admitted and hit.distance<=length and (not closest or hit.distance<closest.distance) then closest=hit end
        end
        if not closest then return 0 end
        ffi.cast('float *',out)[6]=closest.distance;out[7]=closest.unit;return 1
    end
    -- The previous query locks on the incidental body at the muzzle.
    local function previous(...)local args={...};args[6]=5;return scene(unpack(args))end
    assert(api.cast_terrain(previous,2,123,origin,target,456)==true)
    assert(api.cast_terrain(scene,2,123,origin,target,456)==false)
    hits[#hits+1]={distance=10,flags=1,unit=300}
    local blocked,detail=api.cast_terrain(scene,2,123,origin,target,456)
    assert(blocked==true and detail.reason=='static_obstruction' and detail.distance==10)
    -- A target node at the static surface keeps the existing endpoint tolerance.
    assert(api.cast_terrain(scene,2,123,origin,point(0,10,2),456)==false)
    print('PASS: recorded non-static blockers cannot veto fire; static ground behind them still does')
end
