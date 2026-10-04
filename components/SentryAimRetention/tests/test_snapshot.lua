local M=assert(loadfile(assert(arg[1])..'/aim_data.lua'))()
local ffi=require('ffi')
local function bytes(kind,v)return ffi.string(ffi.new(kind..'[1]',v),ffi.sizeof(kind))end
local function fixture()
    local mem={};local game=0x100000;local tm,bm,rm=0x500000,0x600000,0x700000
    local wm,cm=0x900000,0x910000
    local entity,rt,nt,behavior,control=0x800000,0x801000,0x802000,0x803000,0x804000
    local function put(a,b)for i=1,#b do mem[a+i-1]=b:sub(i,i)end end
    local function w(a,n)put(a,bytes('uint32_t',n))end
    local function p(a,n)put(a,bytes('uint64_t',n))end
    local function zero(a,n)put(a,string.rep('\0',n))end
    local api={}
    function api.read(a,n)local t={};for i=0,n-1 do if not mem[a+i]then return nil end;t[#t+1]=mem[a+i]end;return table.concat(t)end
    function api.pointer(b)return b and tonumber(ffi.cast('const uint64_t *',b)[0])end
    function api.read_into(a,n,buffer)
        local b=api.read(a,n);if not b then return false end
        ffi.copy(buffer,b,n);return true
    end
    function api.bind()error('Unvalidated native binding')end
    zero(tm,392);zero(bm,112);zero(rm,96);zero(entity,24);zero(rt,208);zero(nt,24);zero(behavior,504);zero(control,16)
    p(game+0x3326d30,tm);p(game+0x3326740,bm);p(game+0x3326d70,rm)
    p(game+0x3326348,0x990000);p(0x990018,1000000);p(behavior+152,1700000)
    zero(wm,104);zero(cm,96);p(game+0x3326ce0,wm);p(game+0x3326660,cm)
    local fm=0x950000;zero(fm+73808,32);p(game+0x3326cb8,fm)
    p(fm+73808,0x980000);w(fm+73816,8);w(fm+73820,0);w(fm+73824,2)
    zero(0x980000,64);w(0x980010,77);w(0x980014,0)
    p(fm+73832,0x970000);p(0x970000,0x971000);zero(0x971000,20)
    w(0x971008,77);w(0x97100c,222)
    w(tm+308,384);w(tm+320,1);w(tm+324,1)
    w(bm+32,1024);w(rm+8,64);w(rm+20,1);w(rm+24,1)
    for _,spec in ipairs({{tm,336,360,0x810000},{bm,64,88,0x820000},{rm,40,64,0x830000},
        {wm,48,72,0x920000},{cm,40,64,0x930000}})do
        local m,o,e,map=unpack(spec);p(m+o,map);w(m+o+8,8);w(m+o+12,0);w(m+o+16,2)
        zero(map,64);w(map+16,9);w(map+20,0);p(m+e,map+128);p(map+128,entity)
    end
    p(tm+376,rt);p(tm+384,nt);p(bm+96,behavior);p(rm+88,control)
    zero(0x940000,1008);p(wm+88,0x940000);w(0x940000+216,1);w(0x940000+120,15)
    zero(0x941000,12);p(wm+96,0x941000);w(0x941000,1);p(cm+88,0x942000);put(0x942000,'\1')
    put(entity,('\x70\x1d\xe3\x58\xcf\xd6\x85\xef'));w(entity+8,9);w(entity+12,1);w(entity+16,12);put(entity+20,'\1')
    w(behavior,213);w(behavior+8,12);w(behavior+24,77);w(behavior+96,3);put(behavior+120,'\1')
    w(rt,77);put(control,'\1');put(control+8,bytes('float',80));put(control+12,bytes('float',50))
    return api,game,put,w,p,{tm=tm,bm=bm,rm=rm,entity=entity,rt=rt,nt=nt,behavior=behavior,control=control}
end
local api,g,put,w,p,a=fixture()
local rows=M.snapshot(api,g);assert(#rows==1)
local s=rows[1];assert(s.id==9 and s.profile=='Gatling' and s.node==12 and s.target==77)
assert(s.runtime_target==77 and s.flags==0 and s.enabled and s.has)
assert(s.raw_address==a.rt+8 and s.flags_address==a.nt+16 and s.control_address==a.control)
assert(s.fire.mode==1 and s.fire.node==15 and s.fire.trigger and s.fire.pause==16 and s.fire.resume==4)
assert(s.fire.target_unit==222 and #s.fire.target_guards>0)
assert(s.selection.address==a.behavior+152 and s.selection.now==1000000)
assert(s.selection.deadline==bytes('uint64_t',1700000) and #s.selection.guards==1)
do
    local queried=false
    local state={native={
        pose=function()
            return ffi.string(ffi.new('float[16]',{1,0,0,0,0,1,0,0,0,0,1,0,0,-20,0,1}),64)
        end,
        terrain_path=function(unit,origin,target,target_unit)
            queried=true;assert(unit==1 and target==s.raw and #origin==12 and target_unit==222);return false
        end,
    }}
    api.time=function()return 0 end
    assert(M.apply(api,g,nil,state));assert(queried)
end
-- Target removal cannot invalidate restoration of the sentry's fire mode.
do
    local restored=false;local current=bytes('uint32_t',0);local read=api.read
    w(0x971008,78)
    api.read=function(address,size)if address==s.fire.mode_address then return current end;return read(address,size)end
    api.writable_data=function()return true end
    assert(M.release_fire(api,{fire_mode=function(_,_,mode)restored=true;current=bytes('uint32_t',mode)end},
        {snapshot=s,mode=1}))
    assert(restored);api.read=read;w(0x971008,77)
end
local count=0;for _ in pairs(M.profiles)do count=count+1 end;assert(count==7)
put(a.entity+20,'\0');assert(#M.snapshot(api,g)==0)
put(a.entity+20,'\3');assert(#M.snapshot(api,g)==0)
put(a.entity+20,'\1');w(a.behavior,999);assert(not pcall(M.snapshot,api,g));w(a.behavior,213)
w(a.bm+72,7);assert(not pcall(M.snapshot,api,g));w(a.bm+72,8)
p(0x820080,a.entity+24);assert(not pcall(M.snapshot,api,g));p(0x820080,a.entity)
put(a.rt+8,bytes('uint32_t',0x7fc00000));assert(not pcall(M.snapshot,api,g));put(a.rt+8,bytes('float',0))
assert(not pcall(M.apply,api,g,nil,{})) -- no setter signatures, so no binding or mutation
p(g+0x3326d30,0);local ok,why=M.apply(api,g,nil,{})
assert(ok and why=='waiting_for_sentries')
print('PASS: native-layout fixture, offsets, authority/resource gates, malformed maps/vectors and no binding before validation')

-- Discovery remains fresh while contiguous entity-pointer reads are bounded.
do
    local api,g,put,w,p,a=fixture()
    w(a.tm+308,512);w(a.tm+320,512);w(a.tm+324,512)
    for i=0,511 do p(0x810080+i*8,0xa00000+i*32);put(0xa00000+i*32,string.rep('\0',24)) end
    local read=api.read;local calls,batches=0,0
    api.read=function(address,size)
        calls=calls+1;assert(size<=2048,'unbounded registry read')
        if address>=0x810080 and address<0x811080 then batches=batches+1 end
        return read(address,size)
    end
    -- Cold: the targeting root and header, two pointer batches and every entity header.
    local cache=M.new_cache()
    assert(#M.snapshot(api,g,cache)==0 and calls==516 and batches==2,'batch pointer array, classify every entity')
    -- Warm: unchanged pointers keep their class; one changed pointer is read again.
    calls,batches=0,0;assert(#M.snapshot(api,g,cache)==0 and calls==4 and batches==2,'unchanged entries')
    p(0x810080+7*8,0xa10000);put(0xa10000,string.rep('\0',24))
    calls=0;assert(#M.snapshot(api,g,cache)==0 and calls==5,'one changed entry')
    -- Every RESCAN-th check classifies every entry again (authority can change in place).
    for _=cache.checks+1,29 do M.snapshot(api,g,cache) end
    calls=0;M.snapshot(api,g,cache);assert(cache.checks==30 and calls==516,'rescan')
    api.read=function(address,size)if size==2048 then return nil end;return read(address,size)end
    assert(not pcall(M.snapshot,api,g),'failed batch must not produce candidate sentries')
end
print('PASS: 512 non-sentries use two bounded pointer reads and reject failed snapshots')

-- Per-frame call budget through the loader: one check per frame, two (around
-- the game update) while a sentry is engaged. Bound natives (setters, pose,
-- terrain query) are not api calls and are not counted. A sentry's layout is
-- located once and verified on every check from the registry headers, the
-- entity pointers and the entity header the check reads anyway: per check 3
-- map-slot reads, 4 component reads, 2 weapon/trigger header reads, 4 fire
-- reads and the roots, instead of locating everything again.
local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
-- As in the build: the vendored runtime is handed to the loader for its update guard.
local runtime=assert(loadfile(arg[1]..'/bingus_runtime.lua'))()
local memory_file=assert(loadfile(arg[1]..'/bingus_memory.lua'))()
local SENTRY='\x70\x1d\xe3\x58\xcf\xd6\x85\xef'
local function budget_fixture()
    local api,g,put,w,p,a=fixture()
    api.time=function()return 0 end
    api.module=function(n)return n and g or 0x200000 end
    api.module_hash=function(m)return m==g and 'game' or 'exe' end
    -- The runtime's own build check, over the fake modules and hashes.
    local memory=memory_file.new(runtime)
    memory.module,memory.module_hash=api.module,api.module_hash
    api.verify_build=memory.verify_build
    -- A checked write makes no protection query of its own: the caller verified
    -- its range earlier in the frame. Fail if it lies outside every such range.
    -- fail[address] makes the next write there report failure without writing.
    local verified,fail={}, {}
    function api.writable_data(at,n)
        if api.read(at,n)==nil then return false end
        verified[#verified+1]={at,at+n};return true
    end
    local function covered(at,n)
        for _,r in ipairs(verified)do if at>=r[1] and at+n<=r[2] then return true end end
        return false
    end
    function api.write(at,b,checked)
        if checked then assert(covered(at,#b),'checked write outside a range verified this frame')
        elseif not api.writable_data(at,#b) then return false end
        if fail[at] then fail[at]=nil;return false end
        put(at,b);return true
    end
    local native={pose=function()
            return ffi.string(ffi.new('float[16]',{1,0,0,0,0,1,0,0,0,0,1,0,0,-20,0,1}),64)
        end,terrain_path=function()return false end,
        retention=function(_,on)w(a.nt+16,on and 2 or 0)end,
        horizontal=function(_,v)put(a.control+8,bytes('float',v))end,
        vertical=function(_,v)put(a.control+12,bytes('float',v))end,
        fire_mode=function(_,_,mode)w(0x941000,mode)end}
    local counts=budget.wrap(api)
    -- below.raise makes the next game update raise once (an error below this mod).
    local below={}
    local env=setmetatable({print=function()end,CowboyBingusModLoader={api=1,version=7},
        update=function()if below.raise then below.raise=nil;error('vanilla failure')end end},{__index=_G});env._G=env
    setfenv(assert(loadfile(arg[1]..'/archive_loader.lua')),env)()(function()return api end,M,
        {revision='budget',game_sha256='game',exe_sha256='exe'},runtime)
    local f={api=api,g=g,put=put,w=w,p=p,a=a,native=native,env=env,fail=fail,below=below,
        state=assert(env.SentryAimRetention)}
    -- One frame through the loader, checked against limits.
    function f.frame(label,limits)
        for i=#verified,1,-1 do verified[i]=nil end
        local frame=budget.frame(counts,env.update,1/60)
        budget.check(frame,limits,label)
        return frame
    end
    -- One frame whose game update raises: only the check before it runs.
    function f.failing_frame(label,limits)
        for i=#verified,1,-1 do verified[i]=nil end
        below.raise=true
        local frame,ok=budget.frame(counts,pcall,env.update,1/60)
        assert(not ok,label..': the error below reaches the caller')
        budget.check(frame,limits,label)
        return frame
    end
    function f.guard()return env.BingusRuntime.statuses.SentryAimRetention end
    function f.check(label,limits,expected)
        for i=#verified,1,-1 do verified[i]=nil end
        local frame=budget.frame(counts,env.update,1/60)
        assert(f.state.last_reason==expected,label..': '..tostring(f.state.last_reason))
        budget.check(frame,limits,label)
    end
    return f
end
do
    local f=budget_fixture();local a,w,p,put,state,check=f.a,f.w,f.p,f.put,f.state,f.check
    local roots={0x3326d30,0x3326740,0x3326d70}
    for _,rva in ipairs(roots)do p(f.g+rva,0)end
    -- The targeting root is the idle gate; its header the second.
    check('outside a mission',{read=1},'waiting_for_sentries')
    p(f.g+roots[1],a.tm);p(f.g+roots[2],a.bm);p(f.g+roots[3],a.rm);w(a.tm+324,0)
    check('idle in a mission',{read=2,pointer=1},'waiting_for_sentries')
    -- A registered entity's header is read when its pointer first appears (or
    -- changes, or on a rescan); afterwards only the pointer batch is read.
    w(a.tm+324,1);put(a.entity,string.rep('\0',8))
    check('idle, one non-sentry registered',{read=4,pointer=3},'waiting_for_sentries')
    check('idle, the same non-sentry',{read=3,pointer=2},'waiting_for_sentries')
    -- The entity becomes a sentry in place (same pointer): found at the next
    -- rescan, here forced by dropping the cache. Setters bind once when the
    -- first sentry appears; skip that one-off path.
    put(a.entity,SENTRY);state.layout=nil;state.native=f.native;f.env.update(1/60)
    check('sentry tracking',{read=58,read_into=16,pointer=12,time=2},'observing')
    -- Five protection queries (about 1.5 ms in game) once per target loss, one per
    -- range: fire mode, selection deadline, retention flags, aim, turret speeds.
    -- The three writes reuse the query made for their range earlier in the check.
    -- Reads include one per query: this fixture's writable_data reads its range.
    w(a.behavior+24,0);w(a.behavior+96,32)
    check('target lost',{read=156,read_into=16,pointer=12,time=2,writable_data=5,write=3},'firing_paused')
    check('holding aim',{read=54,read_into=16,pointer=12,time=2},'firing_paused')
    assert(state.holds==1 and state.holding==1 and state.fire_pauses==1 and state.reselections==1)
    -- A new target before the native handler used the search request: fire
    -- resumes (1 query), the request is restored (1; its write reuses that
    -- query) and the hold ends (3).
    w(a.behavior+24,77);w(a.behavior+96,3)
    check('target reacquired',{read=152,read_into=16,pointer=12,time=2,writable_data=5,write=1},'observing')
    assert(state.releases==1 and state.fire_resumes==1 and state.holding==0 and state.fire_paused==0)
    w(a.behavior+24,0);w(a.behavior+96,32)
    check('target lost again',{read=156,read_into=16,pointer=12,time=2,writable_data=5,write=3},'firing_paused')
    assert(state.holds==2 and state.reselections==2)
    -- The sentry vanishes while held: the same three releases in one check.
    -- Reads 94 -> 96: the fire guards now also hold the trigger manager root and
    -- the trigger array, because the trigger's address is kept between checks;
    -- each release's identity check reads them.
    w(a.tm+324,0)
    check('sentry removed while held',{read=96,pointer=1,time=1,writable_data=5,write=1},
        'waiting_for_sentries')
    assert(not next(state.records) and not next(state.fire_records))
    check('idle after a sentry',{read=2,pointer=1,time=1},'waiting_for_sentries')
    -- A sentry with no target is not engaged: one check per frame. Its first
    -- check locates it; the next ones verify the kept layout.
    w(a.tm+324,1);w(a.behavior+24,0);w(a.behavior+96,32);w(a.rt,0);put(0x942000,'\0')
    check('sentry placed, no target',{read=52,read_into=8,pointer=23,time=1},'observing')
    check('sentry scanning',{read=26,read_into=8,pointer=6,time=1},'observing')
    assert(not state.engaged)
end
-- A hold that fails halfway is undone in the same check: the search request is
-- restored (1 query), fire resumes (1) and the hold is released (3), its first
-- aim write rolled back inside the range the release just checked (no query of
-- its own). The mod keeps running and starts afresh: the check after the game
-- update waits for the next frame, which pauses fire again for the lost target
-- (1 query) without a hold. The failure is not printed (the guard prints one
-- line per burst), so it reads no clock: 2 -> 1 clock reads.
do
    local f=budget_fixture();local a,w,put,state=f.a,f.w,f.put,f.state
    state.native=f.native;f.env.update(1/60)
    -- The engine's fallback moved the raw aim, and the computed aim write fails.
    local moved=bytes('float',1)..bytes('float',2)..bytes('float',3)
    put(a.rt+8,moved);f.fail[a.rt+20]=true
    w(a.behavior+24,0);w(a.behavior+96,32)
    f.frame('failed hold, then restore',{read=224,read_into=8,pointer=6,time=1,writable_data=10,write=5})
    assert(state.status=='hold_aim_failed',state.status)
    local read=f.api.read
    assert(read(a.rt+8,12)==moved and read(a.nt+16,4)==bytes('uint32_t',0),'aim and retention restored')
    assert(read(a.control+8,8)==bytes('float',80)..bytes('float',50),'speeds restored')
    assert(read(0x941000,4)==bytes('uint32_t',1) and read(a.behavior+152,8)==bytes('uint64_t',1700000))
    assert(not next(state.records) and not next(state.fire_records) and f.guard().errors==1)
    f.check('after a failed hold',{read=113,read_into=16,pointer=29,time=2,writable_data=1},'firing_paused')
    assert(state.holding==0 and state.fire_paused==1 and f.guard().state=='running')
end
-- An update below this mod raised while a sentry was held. The failing frame
-- ran only the check before the game update. The next frame restores what the
-- stop path restores, in place of its checks: the search request (1 query; its
-- write reuses it), fire (1) and the hold (3), about 1.45 ms once in game. Its
-- clock read is the forced log write. Paused frames make no api call at all;
-- after 60 frames whose updates below returned, the mod resumes from a fresh
-- start (fire pauses again for the lost target; no hold without a new track).
do
    local f=budget_fixture();local a,w,state=f.a,f.w,f.state
    state.native=f.native;f.env.update(1/60)
    w(a.behavior+24,0);w(a.behavior+96,32)
    f.check('target lost',{read=156,read_into=16,pointer=12,time=2,writable_data=5,write=3},'firing_paused')
    assert(state.holding==1 and state.fire_paused==1 and state.reselections==1)
    f.failing_frame('update below fails while held',{read=27,read_into=8,pointer=6,time=1})
    -- Reads 90 -> 94: the release identity checks read the trigger manager root
    -- and trigger array guards (see 'sentry removed while held').
    f.frame('paused after an error below',{read=94,time=1,writable_data=5,write=1})
    assert(state.status=='paused_after_update_error' and not state.active,state.status)
    local read=f.api.read
    assert(read(a.nt+16,4)==bytes('uint32_t',0),'retention restored')
    assert(read(a.control+8,8)==bytes('float',80)..bytes('float',50),'speeds restored')
    assert(read(0x941000,4)==bytes('uint32_t',1) and read(a.behavior+152,8)==bytes('uint64_t',1700000),'fire and deadline restored')
    assert(not next(state.records) and not next(state.fire_records) and state.holding==0 and state.fire_paused==0)
    assert(state.native==f.native,'natives stay bound')
    for i=1,59 do f.frame('paused frame '..i,{}) end
    assert(f.guard().state:find('^paused'))
    f.check('resumed, target still lost',{read=113,read_into=16,pointer=29,time=2,writable_data=1},'firing_paused')
    assert(f.guard().state=='running' and state.holding==0 and state.holds==1)
    w(a.behavior+24,77);w(a.behavior+96,3)
    f.check('target back after a pause',{read=96,read_into=16,pointer=16,time=2,writable_data=1},'observing')
end
print('PASS: per-frame call budget: no protection queries and 2 reads idle; a kept sentry layout; holds query protection only when a target is lost or released; a pause restores once and makes no api call while paused')

-- A kept layout follows moved memory. The turret control array moves while the
-- sentry holds aim: the guards see the new array pointer, the sentry is located
-- again, the hold follows it, and when the target returns the speeds the hold
-- saved go to the new address. The old address is never written again. A moved
-- behavior array is followed the same way.
do
    local f=budget_fixture();local a,w,p,put,state=f.a,f.w,f.p,f.put,f.state
    local read=f.api.read
    local control=a.control
    local native={}
    for k,v in pairs(f.native) do native[k]=v end
    native.horizontal=function(_,v)put(control+8,bytes('float',v))end
    native.vertical=function(_,v)put(control+12,bytes('float',v))end
    state.native=native;f.env.update(1/60)
    w(a.behavior+24,0);w(a.behavior+96,32);f.env.update(1/60)
    assert(state.holding==1 and read(a.control+8,8)==string.rep('\0',8),'held with zero speeds')
    control=0x806000;put(control,read(a.control,16));p(a.rm+88,control)
    local poison=string.rep('\255',16);put(a.control,poison)
    f.env.update(1/60)
    local record=state.records[9]
    assert(state.holding==1 and record.lease.snapshot.control_address==control,'the hold follows the move')
    assert(read(record.lease.snapshot.control_address+8,8)==string.rep('\0',8))
    w(a.behavior+24,77);w(a.behavior+96,3);f.env.update(1/60)
    assert(state.holding==0 and state.releases==1,'released on the new target')
    assert(read(control+8,8)==bytes('float',80)..bytes('float',50),'saved speeds restored at the new address')
    assert(read(a.control,16)==poison,'the old address is not written')
    -- The behavior array moves: the next check reads the new one.
    local behavior=0x807000;put(behavior,read(a.behavior,504));p(a.bm+96,behavior)
    put(a.behavior,string.rep('\0',504));f.env.update(1/60)
    local rows=M.snapshot(f.api,f.g,state.layout)
    assert(#rows==1 and rows[1].behavior_address==behavior and rows[1].target==77,'behavior array followed')
end
print('PASS: a kept layout follows moved turret and behavior arrays; a hold keeps its saved speeds and restores them at the new address')

-- The field decoders against ffi: edge values and 200000 random words. NaN words
-- are never loaded through a float cdata here: in this LuaJIT (non-GC64, NaN-tagged
-- values) a NaN payload read that way can become a non-number value, which is why
-- the decoders read the bytes and return a canonical NaN.
do
    local u,f=M.fields.u,M.fields.f
    local function word_bytes(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
    local function same(n)
        local got=f(word_bytes(n),0)
        if math.floor(n/8388608)%256==255 and n%8388608~=0 then return got~=got end
        local c=ffi.new('float[1]');ffi.copy(c,word_bytes(n),4);local want=c[0]
        return got==want and (got~=0 or 1/got==1/want)
    end
    for _,n in ipairs({0,0x80000000,0x3f800000,0xbf800000,0x00000001,0x80000001,0x007fffff,0x00800000,
        0x7f7fffff,0x7f800000,0xff800000,0x7fc00000,0xffbe706d,0x7f800001,0x42a00000}) do
        assert(u(word_bytes(n),0)==n and same(n),string.format('%08x',n))
    end
    math.randomseed(7)
    for _=1,200000 do
        local n=math.random(0,65535)*65536+math.random(0,65535)
        assert(u(word_bytes(n),0)==n and same(n),string.format('%08x',n))
    end
    assert(f('\0\0\0\0\0\0\160\66',4)==80 and u('\1\0\0\0\2\0\0\0',4)==2,'offsets')
    assert(not pcall(u,'\1\2\3',0) and not pcall(f,'\1\2\3\4',1),'a field outside the bytes raises')
end
print('PASS: field decoders match ffi on 200000 words, edge values and NaN payloads, without cdata')
