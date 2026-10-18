-- Idle gate equivalence: the v1.1.0 code (tests/reference/, copied from
-- origin/main) and the current code run side by side through the loader over
-- 2,600 scripted frames, each on its own copy of the same fake game memory.
-- The script covers frames outside a mission, idle frames with a churning
-- targeting registry, a sentry deployed, tracking, losing and reacquiring its
-- target, removed while held, a teammate's sentry, ownership changing in
-- place, an unresolvable sentry, a new sentry at the same address, mission
-- changes, an error below the mod (pause and resume) and a failed read while a
-- sentry is held.
--
-- Every frame compares the writes, native calls, game memory the mod writes,
-- status and counters. The one intended difference: while the current code
-- waits (no sentry this machine controls), a change in the game is seen at the
-- next RESCAN-th check instead of at once (at most 29 frames, 0.5 s at 60
-- FPS). Inside such a window the current code must make no api call, no write
-- and no native call; from its next check on, everything is equal again.
-- Then: gated frames allocate nothing, and a failed read while waiting is seen
-- at the next check.
local source=assert(arg[1])
local tests=arg[0]:gsub('[%w_]+%.lua$','')
local ffi=require('ffi')
local memory_file=assert(loadfile(source..'/bingus_memory.lua'))()
local function bytes(kind,v)return ffi.string(ffi.new(kind..'[1]',v),ffi.sizeof(kind))end
local SENTRY='\x70\x1d\xe3\x58\xcf\xd6\x85\xef'
local G,TM=0x100000,0x500000
local ENTITY,RT,NT,BEHAVIOR,CONTROL=0x800000,0x801000,0x802000,0x803000,0x804000
local TEAMMATE=0xb00000
local POINTERS=0x810080
local MAPS={0x810000,0x820000,0x830000,0x920000,0x930000}

-- One side: a fake game memory (the layout of test_snapshot.lua's fixture), an
-- api that counts its calls, natives that write that memory, and the loader.
local function side(aim_path,loader_path)
    local M=assert(loadfile(aim_path))()
    local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
    local S={mem={},calls=0,journal={},fail={},now=0,tm=TM}
    local mem=S.mem
    local function put(a,b)for i=1,#b do mem[a+i-1]=b:sub(i,i)end end
    local function w(a,n)put(a,bytes('uint32_t',n))end
    local function p(a,n)put(a,bytes('uint64_t',n))end
    local function zero(a,n)put(a,string.rep('\0',n))end
    local function raw(a,n)
        if S.fail[a] then return nil end
        local t={};for i=0,n-1 do if not mem[a+i]then return nil end;t[#t+1]=mem[a+i]end;return table.concat(t)
    end
    S.put,S.w,S.p,S.zero,S.raw=put,w,p,zero,raw
    local function log(line)S.journal[#S.journal+1]=line end
    local api={}
    function api.read(a,n)S.calls=S.calls+1;return raw(a,n)end
    function api.pointer(b)S.calls=S.calls+1;return b and tonumber(ffi.cast('const uint64_t *',b)[0])end
    -- Byte by byte through a byte view made once per buffer: this fake read
    -- allocates nothing, so the allocation tests see only the mod's own.
    local views=setmetatable({},{__mode='k'})
    function api.read_into(a,n,buffer)
        S.calls=S.calls+1
        if S.fail[a] then return false end
        local view=views[buffer]
        if not view then view=ffi.cast('uint8_t *',buffer);views[buffer]=view end
        for i=0,n-1 do
            local byte=mem[a+i]
            if not byte then return false end
            view[i]=byte:byte()
        end
        return true
    end
    function api.time()S.calls=S.calls+1;return S.now end
    function api.bind()error('Unvalidated native binding')end
    api.module=function(n)return n and G or 0x200000 end
    api.module_hash=function(m)return m==G and 'game' or 'exe' end
    local memory=memory_file.new(runtime)
    memory.module,memory.module_hash=api.module,api.module_hash
    api.verify_build=memory.verify_build
    local verified={}
    function api.writable_data(at,n)
        S.calls=S.calls+1;log('query '..at..' '..n)
        if raw(at,n)==nil then return false end
        verified[#verified+1]={at,at+n};return true
    end
    function api.write(at,b,checked)
        S.calls=S.calls+1;log('write '..at..' '..b)
        if checked then
            local inside=false
            for _,r in ipairs(verified)do if at>=r[1] and at+#b<=r[2] then inside=true end end
            assert(inside,'checked write outside a range verified this frame')
        end
        put(at,b);return true
    end
    -- The fixture's memory (test_snapshot.lua), with an empty targeting registry.
    zero(TM,392);zero(0x600000,112);zero(0x700000,96);zero(RT,208);zero(NT,24);zero(BEHAVIOR,504);zero(CONTROL,16)
    p(G+0x3326d30,0);p(G+0x3326740,0x600000);p(G+0x3326d70,0x700000)
    p(G+0x3326348,0x990000);p(0x990018,1000000);p(BEHAVIOR+152,1700000)
    zero(0x900000,104);zero(0x910000,96);p(G+0x3326ce0,0x900000);p(G+0x3326660,0x910000)
    local fm=0x950000;zero(fm+73808,32);p(G+0x3326cb8,fm)
    p(fm+73808,0x980000);w(fm+73816,8);w(fm+73820,0);w(fm+73824,2)
    zero(0x980000,64);w(0x980010,77);w(0x980014,0)
    p(fm+73832,0x970000);p(0x970000,0x971000);zero(0x971000,20)
    w(0x971008,77);w(0x97100c,222)
    w(TM+308,384)
    w(0x600000+32,1024);w(0x700000+8,64);w(0x700000+20,1);w(0x700000+24,1)
    for k,spec in ipairs({{TM,336,360},{0x600000,64,88},{0x700000,40,64},{0x900000,48,72},{0x910000,40,64}})do
        local m,o,e=unpack(spec);local map=MAPS[k]
        p(m+o,map);w(m+o+8,8);w(m+o+12,0);w(m+o+16,2)
        zero(map,64);w(map+16,9);w(map+20,0);p(m+e,map+128);p(map+128,ENTITY)
    end
    zero(POINTERS,384*8)
    p(TM+376,RT);p(TM+384,NT);p(0x600000+96,BEHAVIOR);p(0x700000+88,CONTROL)
    zero(0x940000,1008);p(0x900000+88,0x940000);w(0x940000+216,1);w(0x940000+120,15)
    zero(0x941000,12);p(0x900000+96,0x941000);w(0x941000,1);p(0x910000+88,0x942000);put(0x942000,'\1')
    -- The mission mode record at [game+0x33266a0]; no mission until the script starts one.
    p(G+0x33266a0,0x960000);zero(0x960000,0x44)
    S.native={pose=function(unit,node)
            log('pose '..unit..' '..node)
            return ffi.string(ffi.new('float[16]',{1,0,0,0,0,1,0,0,0,0,1,0,0,-20,0,1}),64)
        end,terrain_path=function(unit)log('terrain '..unit);return false end,
        retention=function(id,on)log('retention '..id..' '..tostring(on));w(NT+16,on and 2 or 0)end,
        horizontal=function(_,v)log('horizontal '..v);put(CONTROL+8,bytes('float',v))end,
        vertical=function(_,v)log('vertical '..v);put(CONTROL+12,bytes('float',v))end,
        fire_mode=function(_,id,mode)log('fire_mode '..id..' '..mode);w(0x941000,mode)end}
    S.below={}
    local env=setmetatable({print=function()end,CowboyBingusModLoader={api=1,version=7},
        update=function()if S.below.raise then S.below.raise=nil;error('vanilla failure')end end},{__index=_G})
    env._G=env
    setfenv(assert(loadfile(loader_path)),env)()(function()return api end,M,
        {revision='equivalence',game_sha256='game',exe_sha256='exe'},runtime)
    S.env,S.M,S.api=env,M,api
    S.state=assert(env.SentryAimRetention)
    -- Bound natives, as after the session's first sentry.
    S.state.native=S.native
    function S.frame()
        for i=#verified,1,-1 do verified[i]=nil end
        for i=#S.journal,1,-1 do S.journal[i]=nil end
        S.calls=0
        local polls=S.state.polls
        local ok,why=pcall(env.update,1/60)
        S.update_error=not ok and tostring(why) or nil
        S.checked=S.state.polls~=polls
    end
    function S.guard()return env.BingusRuntime.statuses.SentryAimRetention end
    return S
end

local A=side(tests..'reference/aim_data.lua',tests..'reference/archive_loader.lua')
local B=side(source..'/aim_data.lua',source..'/archive_loader.lua')
local sides={A,B}
local function each(f)for _,S in ipairs(sides)do f(S)end end

-- The world, written to both memories ------------------------------------------
local entries,registry,mission,next_other={},false,false,0
local function publish()
    each(function(S)
        S.p(G+0x3326d30,registry and S.tm or 0)
        S.w(0x960008,mission and 1 or 0);S.w(0x960040,mission and 1 or 0)
        for i,pointer in ipairs(entries)do
            S.p(POINTERS+8*(i-1),pointer)
            if pointer==ENTITY then S.w(MAPS[1]+20,i-1) end
        end
        S.w(S.tm+320,#entries);S.w(S.tm+324,#entries)
    end)
end
-- A targeting entity that is not a sentry.
local function other()
    next_other=next_other+1
    local address=0xa00000+next_other*32
    each(function(S)S.zero(address,24);S.w(address+8,1000+next_other);S.put(address+20,'\1')end)
    return address
end
local function add(pointer)entries[#entries+1]=pointer end
-- The sentry takes index 0 (its runtime and network rows are at index 0 of
-- their arrays here); the entry there moves to the end.
local function add_sentry()entries[#entries+1]=entries[1];entries[1]=ENTITY end
-- Swap-remove, as the native registry compacts.
local function remove_at(i)entries[i]=entries[#entries];entries[#entries]=nil end
local function remove(pointer)
    for i,e in ipairs(entries)do if e==pointer then return remove_at(i)end end
end
-- Our sentry's entity and components, tracking target 77; authority 1 = ours.
local function sentry(id,authority)
    each(function(S)
        S.zero(ENTITY,24);S.put(ENTITY,SENTRY);S.w(ENTITY+8,id);S.w(ENTITY+12,1);S.w(ENTITY+16,12);S.put(ENTITY+20,authority)
        for _,map in ipairs(MAPS)do S.w(map+16,id)end
        S.zero(BEHAVIOR,152);S.zero(BEHAVIOR+160,344)
        S.w(BEHAVIOR,213);S.w(BEHAVIOR+8,12);S.w(BEHAVIOR+24,77);S.w(BEHAVIOR+96,3);S.put(BEHAVIOR+120,'\1')
        S.zero(RT,32);S.w(RT,77);S.zero(NT,24)
        S.put(CONTROL,'\1\0\0\0');S.put(CONTROL+8,bytes('float',80));S.put(CONTROL+12,bytes('float',50))
        S.w(0x941000,1);S.put(0x942000,'\1')
    end)
end
local function target(id,source_flags)
    each(function(S)S.w(BEHAVIOR+24,id);S.w(BEHAVIOR+96,source_flags)end)
end
local function new_registry(address)
    each(function(S)S.put(address,S.raw(S.tm,392));S.tm=address end)
end

-- The script: frame -> action. Every action changes the game for both sides.
local script={}
local function at(frame,f)script[frame]=f end
-- The ship has a targeting registry (no sentry can exist there); the mission
-- starts 310 frames before the first sentry.
at(50,function()registry=true;for _=1,40 do add(other())end end)
at(90,function()mission=true end)
for frame=100,390,23 do
    at(frame,function()
        remove_at(1+frame%#entries)
        -- Every other time an entity replaces a removed one in the same frame.
        if frame%2==0 then add(other())end
    end)
end
at(400,function()sentry(9,'\1');add_sentry()end)
at(470,function()target(0,32)end)          -- target lost: hold aim, pause fire
at(520,function()target(77,3)end)          -- reacquired
at(560,function()target(0,32)end)          -- lost again
at(600,function()remove(ENTITY)end)         -- removed while held
at(650,function()
    each(function(S)S.zero(TEAMMATE,24);S.put(TEAMMATE,SENTRY);S.w(TEAMMATE+8,10);S.put(TEAMMATE+20,'\0')end)
    add(TEAMMATE)
end)
-- A sentry this machine controls whose maps hold no entry: classified again
-- on every check by both.
at(700,function()each(function(S)S.put(TEAMMATE+20,'\1')end)end)
at(760,function()remove(TEAMMATE)end)
at(850,function()sentry(9,'\0');add_sentry()end)                 -- a teammate's sentry
at(950,function()each(function(S)S.put(ENTITY+20,'\1')end)end)  -- control passes to us in place
at(1000,function()target(0,32)end)
-- A new sentry at the same address and index while the old one is held.
at(1040,function()sentry(13,'\1')end)
at(1080,function()target(0,32)end)
at(1100,function()remove(ENTITY);registry,mission=false,false end)            -- the mission ends
at(1300,function()
    new_registry(0x5a0000);registry,mission=true,true;entries={}
    for _=1,25 do add(other())end
end)
at(1400,function()sentry(9,'\1');add_sentry()end)
at(1450,function()target(0,32)end)
at(1500,function()each(function(S)S.below.raise=true end)end)    -- an error below: pause, resume after 60
at(1600,function()target(77,3)end)
at(1650,function()remove(ENTITY)end)
for frame=1700,1880,31 do at(frame,function()remove_at(1);add(other())end)end
at(1900,function()registry,mission=false,false end)
at(2100,function()new_registry(0x5b0000);registry,mission=true,true;entries={};for _=1,30 do add(other())end end)
at(2200,function()sentry(9,'\1');add_sentry()end)
at(2260,function()target(0,32)end)
at(2300,function()each(function(S)S.fail[BEHAVIOR]=true end)end) -- a failed read while held
at(2301,function()each(function(S)S.fail[BEHAVIOR]=nil end)end)
at(2400,function()remove(ENTITY)end)

-- Side by side ------------------------------------------------------------------
local function view(S)
    local s,g=S.state,S.guard()
    -- Error texts name each side's own file and line.
    local t={(tostring(s.status):gsub('^[^ ]*aim_data%.lua:%d+: ','')),tostring(s.active),tostring(s.engaged),s.observed,s.holding,s.holds,s.releases,s.late_aim,
        s.fire_paused,s.fire_pauses,s.fire_resumes,s.reselections,s.selections,g.state,g.errors,g.lower_errors,
        tostring(S.update_error),S.raw(CONTROL,16),S.raw(RT,32),S.raw(NT,24),S.raw(BEHAVIOR+152,8),S.raw(0x941000,4)}
    for i=1,#t do t[i]=tostring(t[i]):gsub('[^%w_ :.%-]',function(c)return string.format('%%%02x',c:byte())end)end
    return table.concat(t,'|')..'\n'..table.concat(S.journal,'\n')
end
-- Whether S ran a rescan this frame: a check whose number is a multiple of
-- RESCAN (30), or a new layout (every entry is classified on its first check).
local function rescanned(S,layout,checks)
    local c=S.state.layout
    if not c or not S.checked then return false end
    if c~=layout then return true end
    return math.floor(c.checks/30)>math.floor(checks/30)
end
local FRAMES=2600
-- A window opens when the script changes the game while the current code
-- waits. The reference may see an in-place change only at its own rescan,
-- whose phase can differ from the current code's (its second check per
-- frame while a sentry is engaged counts too), so the window closes once both
-- sides have rescanned since the change. Outside a mission the current code
-- does not rescan: its side of a window closes at a mission check that finds
-- no mission. Bounds: 29 frames in a mission, 59 outside (the mission check
-- runs on every 60th frame).
local window,windows,gated,checks_outside,holds_seen=nil,0,0,0,0
local longest={inside=0,outside=0}
for frame=1,FRAMES do
    local action=script[frame]
    if action then
        action();publish()
        -- A later change restarts an open window: both must rescan after it.
        if window or (B.state.layout and B.state.layout.idle) then
            local kind=B.state.layout and B.state.layout.outside==false and 'inside' or 'outside'
            if not window then windows=windows+1 end
            window={open=frame,kind=window and window.kind=='outside' and 'outside' or kind}
        end
    end
    local la,ca=A.state.layout,A.state.layout and A.state.layout.checks or 0
    local lb,cb=B.state.layout,B.state.layout and B.state.layout.checks or 0
    each(function(S)S.now=frame/60;S.frame()end)
    local paused=A.guard().state:find('^paused')
    assert(A.checked or paused,frame..': the reference checks every running frame')
    local mission_checked=false
    if not B.checked and not paused then
        gated=gated+1
        assert(#B.journal==0,frame..': a gated frame made a native call')
        if B.calls>0 then
            -- Only the mission check (2 reads, plus a pointer decode when the
            -- record moved), only on a RESCAN-th frame, and only outside a mission.
            assert(B.calls<=3 and (cb+1)%30==0 and B.state.layout.outside,frame..': a gated frame made '..B.calls..' api calls')
            mission_checked=true;checks_outside=checks_outside+1
        end
    end
    if window then
        window.a=window.a or rescanned(A,la,ca)
        if not window.b and (rescanned(B,lb,cb) or mission_checked) then
            window.b=true;longest[window.kind]=math.max(longest[window.kind],frame-window.open)
        end
        if window.a and window.b then window=nil end
    end
    if not window then
        local a,b=view(A),view(B)
        assert(a==b,frame..': the sides differ\nreference: '..a..'\ncurrent: '..b)
    end
    if A.state.holding>0 then holds_seen=holds_seen+1 end
end
assert(not window and longest.inside<=29 and longest.outside<=59,
    'a change was seen '..longest.inside..' / '..longest.outside..' frames late')
assert(A.state.holds==B.state.holds and A.state.holds>=6,'holds '..A.state.holds)
assert(A.state.fire_pauses>=6 and A.guard().errors>=1 and A.guard().lower_errors==1)
assert(gated>FRAMES/2 and checks_outside>=8,'gated frames '..gated..', mission checks '..checks_outside)
print(string.format('PASS: idle gate equivalent to v1.1.0 over %d frames (%d gated, %d of them mission checks, %d holds, '..
    '%d frames held); %d changes while waiting, seen within %d frames in a mission and %d outside, with no other api call before',
    FRAMES,gated,checks_outside,B.state.holds,holds_seen,windows,longest.inside,longest.outside))

-- Every waiting frame allocates nothing (interpreted and compiled): gated
-- frames, mission checks, and the rescans in a mission (registry header and
-- pointer chunk decoded in place, entity headers classified from a buffer).
-- The measuring loop runs twice: its first run also warms the loop itself (a
-- compiled trace is a collected object); the second run is the measurement.
local function measure(S,n)
    collectgarbage();collectgarbage('stop')
    local frames,checks,leaked=0,0,0
    for _=1,n do
        local before=collectgarbage('count')
        S.frame()
        frames=frames+1
        if S.checked then checks=checks+1 end
        leaked=leaked+(collectgarbage('count')-before)
    end
    collectgarbage('restart')
    return frames,checks,leaked
end
for _,mode in ipairs({'off','on'})do
    if jit then if mode=='off' then jit.off() else jit.on() end end
    for _,in_mission in ipairs({false,true})do
        local S=side(source..'/aim_data.lua',source..'/archive_loader.lua')
        S.p(G+0x3326d30,TM);S.w(TM+320,40);S.w(TM+324,40)
        for i=0,39 do local address=0xa00000+i*32;S.zero(address,24);S.p(POINTERS+8*i,address)end
        S.w(0x960008,in_mission and 1 or 0);S.w(0x960040,in_mission and 1 or 0)
        for _=1,120 do S.frame()end
        assert(S.state.layout.idle and S.state.status=='waiting_for_sentries')
        -- Compiled: traces of the rescan path finish compiling over the first runs.
        measure(S,3000);measure(S,3000);measure(S,3000)
        local frames,checks,leaked=measure(S,3000)
        local where=in_mission and 'in a mission' or 'outside a mission'
        assert(checks==(in_mission and 100 or 0),where..': '..checks..' full checks')
        assert(leaked==0,mode..', '..where..': '..frames..' frames ('..checks..' rescans) allocated '..
            (leaked*1024)..' bytes')
    end
end
if jit then jit.on() end
print('PASS: 3000 waiting frames allocate 0 bytes outside a mission (no rescan) and in a mission '..
    '(100 rescans of 40 entries), JIT off and on')

-- A failed read while waiting: the reference raises on that frame, the current
-- code at its next check (no read in between). A read failing on 8 frames in a
-- row stops the reference; the current code counts one error per check.
do
    local R=side(tests..'reference/aim_data.lua',tests..'reference/archive_loader.lua')
    local C=side(source..'/aim_data.lua',source..'/archive_loader.lua')
    for _,S in ipairs({R,C})do
        S.p(G+0x3326d30,TM);S.w(TM+320,1);S.w(TM+324,1);S.zero(0xa00000,24);S.p(POINTERS,0xa00000)
        S.w(0x960008,1);S.w(0x960040,1) -- in a mission
    end
    for _=1,45 do R.frame();C.frame()end
    assert(C.state.layout.idle and not C.checked)
    R.fail[TM+308]=true;C.fail[TM+308]=true
    local seen
    for n=1,30 do
        R.frame();C.frame()
        assert(R.guard().errors==math.min(n,8),'the reference raises on every frame')
        if C.checked then seen=n;break end
        assert(C.calls==0 and C.guard().errors==0)
    end
    assert(seen and seen<=30 and C.guard().errors==1 and C.state.layout==nil,'seen at the next check')
    R.fail[TM+308]=nil;C.fail[TM+308]=nil
    for _=1,40 do R.frame();C.frame()end
    -- 8 failing frames in a row stopped the reference; the current code raised
    -- once (one read per check) and waits again.
    assert(R.guard().state:find('^stopped') and C.state.status=='waiting_for_sentries')
    assert(C.state.layout.idle and C.guard().state=='running')
    print('PASS: a failed read while waiting is seen at the next check ('..seen..' frames later), then the mod waits again')
end
-- Trace starts that keep aborting. The runtime guard calls step and after
-- under pcall on every frame, so a trace started at their entry (or in the
-- gate, or in engaged, which returned into the pcall'd apply's caller) aborted
-- where it returned: "NYI: return to lower frame", retried again and again.
-- That is error 18 in the game's lua51.dll (2.1.0-alpha) and 16 in current
-- LuaJIT 2.1 (lj_traceerr.h NYIRETL). Now step, after, the gate and engaged run interpreted. The
-- driver stays interpreted, as the game calls the hook chain from C. Counted:
-- aborts in the mod's files over 3000 waiting frames. Loops of the full check
-- that leave after few iterations (error 8) still abort, as in v1.1.0, on the
-- one check in 30 that runs. Control: v1.1.0 over the same frames.
local has_util,util=pcall(require,'jit.util')
if jit and jit.attach and has_util and jit.status() then
    local function aborts(aim_path,loader_path)
        local S=side(aim_path,loader_path)
        S.p(G+0x3326d30,TM);S.w(TM+320,3);S.w(TM+324,3)
        for i=0,2 do local address=0xa00000+i*32;S.zero(address,24);S.p(POINTERS+8*i,address)end
        S.w(0x960008,1);S.w(0x960040,1) -- in a mission: the rescans run
        local counts={all=0}
        local function on_trace(what,_,func,_,code)
            if what~='abort' or not func then return end
            local where=util.funcinfo(func).source or ''
            if where:find('aim_data%.lua') or where:find('archive_loader%.lua') then
                counts.all=counts.all+1;counts[code]=(counts[code] or 0)+1
            end
        end
        local function drive()for _=1,3000 do S.frame()end end
        jit.off(drive);jit.off(S.frame)
        jit.attach(on_trace,'trace')
        local ok,why=pcall(drive)
        jit.attach(on_trace)
        assert(ok,why)
        return counts
    end
    local LOWER=jit.version=='LuaJIT 2.1.0-alpha' and 18 or 16
    local control=aborts(tests..'reference/aim_data.lua',tests..'reference/archive_loader.lua')
    local now=aborts(source..'/aim_data.lua',source..'/archive_loader.lua')
    assert((control[LOWER] or 0)>0,'control: v1.1.0 did not return to a lower frame, so this test proves nothing')
    assert(not now[LOWER],tostring(now[LOWER])..' traces returned to a lower frame (v1.1.0: '..control[LOWER]..')')
    assert(now.all<control.all,now.all..' aborts, v1.1.0 '..control.all)
    print('PASS: 3000 waiting frames: no trace returns to a lower frame (v1.1.0: '..control[LOWER]..'); aborts in the mod '..
        control.all..' -> '..now.all)
end
