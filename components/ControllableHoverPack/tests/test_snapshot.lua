local ffi=require('ffi')
local source=assert(arg[1]);local patch=assert(loadfile(source..'/hover_data.lua'))()
patch.policy=assert(loadfile(source..'/cancel.lua'))()
local rows={};local function put(a,b)for i=1,#b do rows[a+i-1]=b:sub(i,i)end end
local function u(x)return ffi.string(ffi.new('uint32_t[1]',x),4)end
local function p(x)return ffi.string(ffi.new('uint64_t[1]',x),8)end
local function f(x)return ffi.string(ffi.new('float[1]',x),4)end
local function zero(a,n)put(a,string.rep('\0',n))end
local function ent(a,hex,id,unit,owned)
    put(a,hex:gsub('..',function(x)return string.char(tonumber(x,16))end):reverse()..u(id)..u(unit)..u(5)..u(owned and 1 or 0))
end
local G=0x10000000;local nextmap=0x20000000
local function map(a,key,index)
    local t=nextmap;nextmap=nextmap+0x100
    put(a,p(t)..u(8)..u(0xffffffff)..u(1))
    for i=0,7 do put(t+8*i,u(0xffffffff)..u(0xffffffff))end
    put(t+8*(key%8),u(key)..u(index))
end
local mode,pm,em,am,eq,jm,attach=0x30000000,0x31000000,0x32000000,0x34000000,0x35000000,0x36000000,0x37000000
for rva,a in pairs({[0x33266a0]=mode,[0x3326468]=pm,[0x346bf98]=em,[0x3326d20]=am,[0x3326738]=eq,[0x3326bb8]=jm,[0x3326dc0]=attach})do put(G+rva,p(a))end
-- The registry blocks the kept layout reads in one piece, readable as in game.
zero(am+0x6c,0xec);zero(eq+64,24);zero(jm+16,72)
zero(mode,0x44);put(mode+8,u(1));put(mode+0x40,u(1))
put(pm+0x84,u(2)..u(2));put(pm+0xe8,p(0x40000000));ent(0x40000000,'1111111111111111',10,99,true)
put(pm+0x3a8,u(391));map(em+0xf22ec8,391,2)
local avatar=em+0xf32f18+48;ent(avatar,'4d1c334d294dfa97',513,391,true)
map(am+0xf8,513,1);put(am+0x6c,u(2));put(am+0x118,p(avatar)) -- local index ONE
map(eq+40,513,1);put(eq+64,p(0x41000000));put(0x41000008,p(avatar));put(eq+80,p(0x42000000));put(0x42000000+48+12,u(524))
map(jm+32,524,1);put(jm+16,u(2)..u(2));put(jm+56,p(0x43000000));put(0x43000008,p(0x44000000));ent(0x44000000,'5ec80f4f1cdb66cf',524,250,true)
map(attach+32,524,1);put(attach+64,p(0x45000000));put(0x45000000+48+4,u(513))
local flags=am+0x53d900+0x1238+0xf80;zero(flags,24);put(flags+8,u(4));put(flags+12,u(4))
put(jm+80,p(0x46000000));put(0x46000005,'\1\0\1\0\1')
local input=am+0x150+0xa7aec+0x1b68+15*32;zero(input,32)
local focused=true;local commands=0;local missing
local api={focused=function()return focused end}
api.pointer=function(b,o)if not b then return nil end;local v=ffi.new('uint64_t[1]');ffi.copy(v,b:sub((o or 0)+1),8);return tonumber(v[0])~=0 and tonumber(v[0]) or nil end
-- As the Windows adapter: read(a, n) returns a string, and read(a, n, into,
-- offset) copies into the caller buffer and returns true. Like
-- ReadProcessMemory, that copy is a C call: it allocates nothing, and compiled
-- code cannot reuse loads of the buffer from before it.
ffi.cdef('void hd2chpt_RtlMoveMemory(uint64_t destination, uint64_t source, size_t length) __asm__("RtlMoveMemory");')
local kernel=ffi.load('kernel32')
local staging=ffi.new('uint8_t[256]');local staging_address=tonumber(ffi.cast('uintptr_t',staging))
api.read=function(a,n,into,offset)
    if missing==a then return nil end
    if into then
        for i=0,n-1 do local c=rows[a+i];if not c then return nil end;staging[i]=c:byte()end
        kernel.hd2chpt_RtlMoveMemory(into.address+(offset or 0),staging_address,n)
        return true
    end
    local b={};for i=0,n-1 do if not rows[a+i] then return nil end;b[#b+1]=rows[a+i]end;return table.concat(b)
end
patch.settings={cancel=function(_,_,s)assert(s.manager==jm and s.pack==524);commands=commands+1;return true end,
    restore=function(_,_,state)state.lease=nil;return true end}
local state={}
local snap=assert(patch.snapshot(api,G));assert(snap.flight and not snap.down and snap.pack==524)
-- Mission +0x40 is a type, not a boolean. Type 2 was captured live during
-- Evacuate High-Value Assets; the native player path accepts types 1 through 7.
for kind=1,7 do
    put(mode+0x40,u(kind));assert(patch.snapshot(api,G),'valid mission type rejected: '..kind)
end
for _,kind in ipairs({0,8,0xffffffff})do
    put(mode+0x40,u(kind));assert(select(2,patch.snapshot(api,G))=='waiting_for_mission')
end
put(mode+0x40,u(2));put(mode+8,u(0));assert(select(2,patch.snapshot(api,G))=='waiting_for_mission')
put(mode+8,u(1)) -- run all remaining ownership/input guards in mission type 2
put(input+8,f(.3));patch.apply(api,G,0,state,1/60);assert(commands==0)
put(input+8,f(0));patch.apply(api,G,0,state,1/60)
put(input+8,f(.01));assert(patch.apply(api,G,0,state)=='cancel_requested');assert(commands==1)
patch.apply(api,G,0,state);assert(commands==1)
focused=false;patch.apply(api,G,0,state);focused=true;patch.apply(api,G,0,state);assert(commands==1)
-- Owner mismatch, wrong resource, missing live data, and local-not-zero all use production reader.
put(0x45000000+48+4,u(999));assert(select(2,patch.snapshot(api,G))=='pack_not_attached');patch.apply(api,G,0,state)
put(0x45000000+48+4,u(513));ent(0x44000000,'073270650f859dd0',524,250,true);assert(select(2,patch.snapshot(api,G))=='not_hover_pack')
ent(0x44000000,'5ec80f4f1cdb66cf',524,250,true)
missing=pm+0x3a8;assert(patch.apply(api,G,0,state)=='waiting_for_read');missing=nil
patch.apply(api,G,0,state);assert(commands==1)
put(input+8,f(0));patch.apply(api,G,0,state);put(input+8,f(.01));patch.apply(api,G,0,state);assert(commands==2)
-- Native action inhibited during ragdoll, swim, ordinary grounded movement.
for _,offset in ipairs({12,8})do
 local old=api.read(flags+offset,4);put(flags+offset,u(offset==12 and 0x14 or 0x80000004));assert(not patch.snapshot(api,G).flight);put(flags+offset,old)
end
put(0x46000005,'\0\0\1\0\0');assert(not patch.snapshot(api,G).flight)
-- Landing assistance remains an active flight, but is not a new cancel window.
put(0x46000005,'\1\1\1\0\1');snap=patch.snapshot(api,G);assert(snap.active and not snap.flight)
state.lease={key=snap.key};focused=false
assert(patch.apply(api,G,0,state)=='native_descent' and state.lease)
put(0x46000005,'\0\0\1\0\0');patch.apply(api,G,0,state);assert(not state.lease)
focused=true
-- +0x14 is the locally simulated prefix, inside the +0x10 active prefix.
put(jm+16,u(3)..u(2));assert(patch.snapshot(api,G).pack==524)
put(jm+16,u(3)..u(1));assert(select(2,patch.snapshot(api,G))=='pack_not_owned')
put(jm+16,u(2)..u(2))
-- A press is confirmed by locating the pack afresh before the native call:
-- a change the kept layout does not read (here the player count) refuses it,
-- and the flight then needs a release and a new press.
put(0x46000005,'\1\0\1\0\1');put(input+8,f(0));patch.apply(api,G,0,state);patch.apply(api,G,0,state)
local cancels=commands;put(pm+0x84,u(0)..u(0));put(input+8,f(.01))
assert(patch.apply(api,G,0,state)=='snapshot_changed' and commands==cancels)
put(pm+0x84,u(2)..u(2));assert(patch.apply(api,G,0,state)=='watching_hover' and commands==cancels)
put(input+8,f(0));patch.apply(api,G,0,state);put(input+8,f(.01))
assert(patch.apply(api,G,0,state)=='cancel_requested' and commands==cancels+1)
-- The kept layout notices a replacement attachment, a moved equipment row and
-- a registry slot that no longer holds the pack: each resolves afresh.
put(0x45000000+48+4,u(999));assert(select(2,patch.snapshot(api,G))=='pack_not_attached');put(0x45000000+48+4,u(513))
assert(patch.snapshot(api,G).pack==524)
put(eq+80,p(0x42100000));put(0x42100000+48+12,u(0));assert(select(2,patch.snapshot(api,G))=='no_backpack')
put(eq+80,p(0x42000000));assert(patch.snapshot(api,G).pack==524)
put(0x43000008,p(0x44100000));local ok,why=pcall(patch.snapshot,api,G);assert(not ok and why.reason=='waiting_for_read')
put(0x43000008,p(0x44000000))
assert(patch.snapshot(api,G).pack==524)
-- A NaN or negative held time is unsupported input, decoded from its bits.
for _,bad in ipairs({'\0\0\192\127','\0\0\192\255','\0\0\128\191'})do
    put(input+8,bad);assert(not pcall(patch.snapshot,api,G))
end
put(input+8,f(0));assert(patch.snapshot(api,G))
-- Keep the production hook installed across mission teardown and re-entry.
-- A registry can temporarily disagree with an entity while it is removed.
put(0x45000000+48+4,u(513));put(input+8,f(0))
api.time=function()return 1 end
api.module=function(name)return name and G or 2 end
api.module_hash=function(m)return tostring(m)end
local e=setmetatable({CowboyBingusModLoader={api=1,version=12},print=function()end,
    os={getenv=function()end}}, {__index=_G})
e._G=e;e.update=function(...)return ... end
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
setfenv(assert(loadfile(source..'/archive_loader.lua'))(),e)(function()return api end,patch,
    {revision='test',game_sha256=tostring(G),exe_sha256='2'},runtime)
local function tick()e.update(1/60)end
local function flight()
    put(0x46000005,'\0\0\1\0\0');tick()
    put(0x46000005,'\1\0\1\0\1');put(input+8,f(.3));tick()
    put(input+8,f(0));tick()
    local before=commands;put(input+8,f(.01));tick()
    assert(commands==before+1,'cancellation stopped after mission transition')
end
flight()
for kind=1,7 do put(mode+0x40,u(kind));flight()end
put(mode+0x40,u(2))
for _,transition in ipairs({
    {am+0x6c,u(0),'avatar registry removal'},
    {0x44000000+8,u(525),'pack registry replacement'},
    {eq+64,p(0),'equipment pointer unavailable'},
    {pm+0x84,u(0)..u(0),'local player removed'},
    {mode+0x40,u(0),'return to ship'},
})do
    local address,bytes=transition[1],transition[2];local original=api.read(address,#bytes)
    put(address,bytes);local before=commands;tick();tick()
    assert(commands==before,'cancellation during '..transition[3])
    put(address,original)
    -- Mission re-entry replaces the pack generation, without reinstalling Lua.
    put(0x44000000+16,u(5+commands));flight()
end
-- A persistent invalid registry remains read-only, then recovers when valid.
local original=api.read(am+0x6c,4);put(am+0x6c,u(0));local before=commands
for i=1,20 do tick()end
assert(commands==before);put(am+0x6c,original);flight()
assert(e.HoverPackCancel.snapshot_waits>=2 and e.HoverPackCancel.last_snapshot_error)
-- A pause starts afresh: after an update below raised, a jump pressed and
-- held through the pause cannot cancel when the mod works again (60 clean
-- frames later); a release and a new press can.
do
    local fail=false
    local p=setmetatable({CowboyBingusModLoader={api=1,version=12},print=function()end,
        os={getenv=function()end}}, {__index=_G})
    p._G=p;p.update=function(...)if fail then error('update below failed',0) end;return ... end
    setfenv(assert(loadfile(source..'/archive_loader.lua'))(),p)(function()return api end,patch,
        {revision='test',game_sha256=tostring(G),exe_sha256='2'},runtime)
    local function frame()return pcall(p.update,1/60)end
    put(0x46000005,'\1\0\1\0\1');put(input+8,f(0));frame();frame()
    assert(p.HoverPackCancel.status=='watching_hover')
    put(input+8,f(.3));fail=true;assert(not frame());fail=false
    local before=commands
    for _=1,60 do assert(frame())end
    assert(p.HoverPackCancel.status=='paused: the previous update failed' and p.HoverPackCancel.updates==2)
    assert(frame() and p.HoverPackCancel.status=='watching_hover' and commands==before,'a held jump cancelled after the pause')
    put(input+8,f(0));frame();put(input+8,f(.01));frame()
    assert(p.HoverPackCancel.status=='cancel_requested' and commands==before+1)
    put(input+8,f(0))
end
print('PASS: after an update error below the mod pauses and starts afresh: a jump held through the pause cannot cancel, a release and a new press can')
-- Per-frame call budget through the installed hook (one check per frame). The
-- settings writes are stubbed here and budgeted in test_settings.lua.
do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local counts=budget.wrap(api);local hook=e.HoverPackCancel
    local function check(label,limits,expected)
        local frame=budget.frame(counts,tick)
        assert(hook.status==expected,label..': '..tostring(hook.status))
        budget.check(frame,limits,label)
    end
    -- Pointers decode in place from the snapshot's buffer: no api.pointer calls.
    -- The first frame in a mission, and any frame on which the kept layout no
    -- longer matches, locates everything (41 reads with a hover pack); the
    -- frames after it read only the kept layout (16 with a hover pack).
    put(input+8,f(0));put(mode+0x40,u(0))
    check('outside a mission',{read=2},'waiting_for_mission');put(mode+0x40,u(2))
    put(0x42000000+48+12,u(0))
    check('no backpack, first frame in a mission',{read=25},'no_backpack')
    check('no backpack',{read=8},'no_backpack');put(0x42000000+48+12,u(524))
    ent(0x44000000,'073270650f859dd0',524,250,true)
    -- 8 reads of the kept layout find a backpack again, then 30 locate it.
    check('backpack equipped, first frame',{read=38},'not_hover_pack')
    check('other jump pack',{read=11},'not_hover_pack');ent(0x44000000,'5ec80f4f1cdb66cf',524,250,true)
    put(0x46000005,'\0\0\1\0\0');tick()
    -- Without a flight no cancellation can start: only the snapshot runs, with
    -- no focus check.
    check('hover pack idle',{read=16},'waiting_for_hover')
    put(0x46000005,'\1\0\1\0\1');tick()
    check('hover flight',{read=16,focused=1},'watching_hover')
    put(input+8,f(.01))
    -- The press locates the pack afresh (41 reads) before the settings write.
    check('cancel press',{read=57,focused=2},'cancel_requested')
    hook.lease={key=patch.snapshot(api,G).key}
    check('native descent',{read=16},'native_descent')
    put(0x46000005,'\0\0\1\0\0')
    check('flight ended, lease released',{read=16},'waiting_for_hover')
    assert(not hook.lease)
end
print('PASS: per-frame call budget: no protection queries without a cancellation')
-- Garbage through the installed hook: idle and flight frames allocate
-- nothing, interpreted (the worst case) or compiled. The JIT itself allocates
-- while it compiles a trace, so compiled frames are counted in a 100-frame
-- window in which it compiled nothing.
do
    local compiling=0
    local function count(what)if what=='start' or what=='stop' then compiling=compiling+1 end end
    jit.attach(count,'trace') -- lint-ok: R5 test only: tells JIT work from frame garbage
    local function garbage()
        collectgarbage('collect');collectgarbage('stop') -- lint-ok: R4 test only: counts garbage with the collector stopped
        local start,events=collectgarbage('count'),compiling
        for _=1,100 do tick()end
        local bytes=(collectgarbage('count')-start)*1024
        collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped
        return bytes,compiling==events
    end
    local function check(label,compiled)
        for _=1,200 do tick()end
        for _=1,50 do
            local bytes,quiet=garbage()
            if quiet or not compiled then assert(bytes==0,label..': '..bytes..' bytes in 100 frames');return end
        end
        error(label..': the JIT never settled')
    end
    for _,compiled in ipairs({false,true})do
        if compiled then jit.on() else jit.off();jit.flush() end -- lint-ok: R5 test only: measures the interpreter, then compiled code
        local label=compiled and 'compiled' or 'interpreted'
        put(0x46000005,'\0\0\1\0\0');put(input+8,f(0))
        check(label..' idle frames',compiled);assert(e.HoverPackCancel.status=='waiting_for_hover')
        put(0x46000005,'\1\0\1\0\1');put(input+8,f(.3));tick();put(input+8,f(0))
        check(label..' flight frames',compiled);assert(e.HoverPackCancel.status=='watching_hover')
    end
    jit.attach(count) -- lint-ok: R5 test only: detaches the handler above
end
print('PASS: no garbage on idle or flight frames, interpreted or compiled')
print('PASS: installed production hook recovers through repeated mission/player/pack transitions without reload')
print('PASS: production snapshot at local index one, exact pack/holder, input, recovery, focus, ordinary pack, grounded/ragdoll/swim and stale guards')
