-- The idle gate against v1.8: tests/reference holds hover_data.lua and
-- archive_loader.lua of v1.8 (origin/main 299c262). Both run side by side,
-- each installed through its own loader on one scripted game memory, for
-- several thousand frames: ship and mission, no backpack, another jump pack,
-- the hover pack idle, flights with presses, landing assistance, the player
-- removed, respawns (a new pack generation), registry moves, read failures
-- and update errors below the mod. Every settings call (cancel, restore) and
-- every printed line must match frame for frame. A status may differ only on
-- a frame the gate answered, and only within the gate's window after a change
-- it does not read (a context change, a one-frame read failure).
local ffi=require('ffi')
local source=assert(arg[1]);local tests=arg[0]:gsub('[%w_]+%.lua$','')
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
zero(am+0x6c,0xec);zero(eq+64,24);zero(jm+16,72)
zero(mode,0x44);put(mode+8,u(1));put(mode+0x40,u(2))
put(pm+0x84,u(2)..u(2));put(pm+0xe8,p(0x40000000));ent(0x40000000,'1111111111111111',10,99,true)
put(pm+0x3a8,u(391));map(em+0xf22ec8,391,2)
local avatar=em+0xf32f18+48;ent(avatar,'4d1c334d294dfa97',513,391,true)
map(am+0xf8,513,1);put(am+0x6c,u(2));put(am+0x118,p(avatar))
map(eq+40,513,1);put(eq+64,p(0x41000000));put(0x41000008,p(avatar));put(eq+80,p(0x42000000));put(0x42000000+48+12,u(524))
map(jm+32,524,1);put(jm+16,u(2)..u(2));put(jm+56,p(0x43000000));put(0x43000008,p(0x44000000))
local HOVER,OTHER='5ec80f4f1cdb66cf','073270650f859dd0'
local generation=250;ent(0x44000000,HOVER,524,generation,true)
map(attach+32,524,1);put(attach+64,p(0x45000000));put(0x45000000+48+4,u(513))
local flags=am+0x53d900+0x1238+0xf80;zero(flags,24);put(flags+8,u(4));put(flags+12,u(4))
put(jm+80,p(0x46000000));put(0x46000000,'\0\0\1\0\0');put(0x46000005,'\0\0\1\0\0')
local input=am+0x150+0xa7aec+0x1b68+15*32;zero(input,32)
local missing -- an address that fails to read for one frame
local fail=false -- the update below the mods raises this frame

-- One installed side: its own module copies, api (counting reads), loader
-- environment, settings stub and log of settings calls and printed lines.
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local function side(hover_path,loader_path)
    local patch=assert(loadfile(hover_path))()
    patch.policy=assert(loadfile(source..'/cancel.lua'))()
    local s={log={},reads=0,frame=0,patch=patch}
    local api={focused=function()return true end,time=function()return s.frame/60 end,
        module=function(name)return name and G or 2 end,module_hash=function(m)return tostring(m)end}
    api.read=function(a,n,into,offset)
        s.reads=s.reads+1
        if missing==a then return nil end
        for i=0,n-1 do if not rows[a+i] then return nil end end
        if into then
            for i=0,n-1 do into.data[(offset or 0)+i]=rows[a+i]:byte()end
            return true
        end
        local b={};for i=0,n-1 do b[#b+1]=rows[a+i]end;return table.concat(b)
    end
    patch.settings={
        cancel=function(_,_,t,state)
            s.log[#s.log+1]=s.frame..' cancel '..t.key:byte(-1)..' '..t.pack
            state.lease={key=t.key};return true
        end,
        restore=function(_,_,state)
            if not state.lease then return true end
            s.log[#s.log+1]=s.frame..' restore';state.lease=nil;return true
        end}
    local e=setmetatable({CowboyBingusModLoader={api=1,version=12},os={getenv=function()end}},{__index=_G})
    e.print=function(line)s.log[#s.log+1]=s.frame..' print '..tostring(line)end
    e._G=e;e.update=function(...)if fail then error('update below failed',0) end;return ... end
    setfenv(assert(loadfile(loader_path))(),e)(function()return api end,patch,
        {revision='test',game_sha256=tostring(G),exe_sha256='2'},runtime)
    s.hook=e.HoverPackCancel
    function s.tick()s.frame=s.frame+1;s.reads=0;pcall(e.update,1/60)end
    return s
end
local old=side(tests..'reference/hover_data.lua',tests..'reference/archive_loader.lua')
local new=side(source..'/hover_data.lua',source..'/archive_loader.lua')

-- A small deterministic generator (LCG): the same script on every run.
local seed=12345
local function random(n)seed=(seed*1103515245+12345)%2147483648;return seed%n end
local frames,since_change,mismatches,explained,gated_frames,failures=0,1000,0,0,0,0
local function frame()
    frames=frames+1;since_change=since_change+1
    old.tick();new.tick()
    missing=nil
    -- Answered by the gate: at most its one row read, where v1.8 checked.
    local gated=new.reads<=1 and old.reads>=2
    if gated then gated_frames=gated_frames+1 end
    assert(#old.log==#new.log,'frame '..frames..': settings calls or lines differ')
    for i=1,#old.log do assert(old.log[i]==new.log[i],'frame '..frames..': '..old.log[i]..' / '..new.log[i])end
    assert((old.hook.lease==nil)==(new.hook.lease==nil) and old.hook.cancellations==new.hook.cancellations,
        'frame '..frames..': lease or cancellations differ')
    if old.hook.status~=new.hook.status then
        mismatches=mismatches+1
        assert(gated and since_change<60,'frame '..frames..': '..old.hook.status..' / '..new.hook.status)
        explained=explained+1
    end
    fail=false
end
local function idle(n,presses)
    for _=1,n do
        if presses and random(8)==0 then put(input+8,f(random(2)==0 and 0 or .02))end
        if random(400)==0 then missing=pm+0x3a8;since_change=0 end
        frame()
    end
    put(input+8,f(0))
end
-- A change the gate does not read: the flight after it starts a full window
-- later, as a drop, pickup or respawn takes longer than the window.
local function change(apply)apply();since_change=0;idle(60+random(60),true)end
local CHANGES={
    function()put(mode+0x40,u(0))end, -- back on the ship
    function()put(mode+0x40,u(1+random(7)))end, -- a mission
    function()put(0x42000000+48+12,u(0))end, -- backpack dropped
    function()put(0x42000000+48+12,u(524))end, -- backpack picked up
    function()ent(0x44000000,OTHER,524,generation,true)end, -- another jump pack
    function()ent(0x44000000,HOVER,524,generation,true)end, -- the hover pack
    function()put(pm+0x84,u(0)..u(0))end, -- the local player removed
    function()put(pm+0x84,u(2)..u(2))end, -- the local player back
    function()generation=generation+1;ent(0x44000000,HOVER,524,generation,true)end, -- respawn: a new pack
}
-- The jump-pack registry compacts: the pack moves to row 0 (or back to 1).
local function move(index)
    map(jm+32,524,index);put(0x43000000+8*index,p(0x44000000));put(0x43000008-8*index,p(0))
end
CHANGES[#CHANGES+1]=function()move(0)end
CHANGES[#CHANGES+1]=function()move(1)end
-- The state row of the pack's current registry row.
local function row_of_pack()
    -- Probe the current jump-pack map (the newest map written at jm+32).
    local data=0
    for i=0,7 do data=data+rows[jm+32+i]:byte()*256^i end
    for i=0,7 do
        local key=0;for j=0,3 do key=key+rows[data+8*i+j]:byte()*256^j end
        if key==524 then local index=rows[data+8*i+4]:byte();return 0x46000000+5*index end
    end
end
local function fly()
    local row=row_of_pack()
    put(row,'\1\0\1\0\1');put(input+8,f(.3))
    for _=1,10+random(30)do frame()end
    for _=1,40+random(160)do
        if random(4)==0 then put(input+8,f(rows[input+8]=='\0' and random(2)==0 and .02 or 0))end
        if random(50)==0 then put(row,'\1\1\1\0\1')end -- the landing assistance latches
        if random(1500)==0 and failures<6 then fail=true;failures=failures+1 end -- an update below raises (fewer than the 8 that stop the mod)
        frame()
    end
    put(row,'\0\0\1\0\0');put(input+8,f(0))
end
for _=1,60 do frame()end -- installation, first full checks
-- Changes come in pairs (a change, later its undoing); a respawn and a
-- registry move stand alone. Flights happen in every state.
for _=1,160 do
    local roll=random(10)
    if roll<3 then
        local pair=1+2*random(4)
        change(CHANGES[pair]);if random(3)==0 then fly()end;change(CHANGES[pair+1])
    elseif roll<4 then change(CHANGES[9+random(3)])
    elseif roll<8 then fly();idle(1+random(40),true)
    else idle(30+random(90),true)
    end
end
assert(frames>=2000,'too few frames: '..frames)
assert(old.hook.cancellations>=20,'too few cancellations: '..old.hook.cancellations)
assert(old.hook.status:sub(1,7)~='stopped','the mods stopped: '..old.hook.status)
assert(gated_frames>frames/2,'the gate answered too few frames: '..gated_frames)
print(('PASS: idle gate equals v1.8 over %d frames (%d answered by the gate, %d cancellations, %d update errors below): every settings call and line identical; %d status differences, all on gated frames within 60 frames of a change the gate does not read'):format(
    frames,gated_frames,old.hook.cancellations,failures,explained))

-- The bounded delay, the cost of the gate: a registry move right before a
-- flight leaves the gate reading the old row, so the flight is seen at the
-- next full check, at most 29 frames late; v1.8 sees it at once.
do
    change(CHANGES[#CHANGES]);idle(5)
    assert(row_of_pack()==0x46000005 and new.hook.status=='waiting_for_hover')
    move(0)
    local moved=row_of_pack();assert(moved==0x46000000)
    put(moved,'\1\0\1\0\1');put(input+8,f(.3))
    local seen
    for i=1,30 do
        old.tick();new.tick()
        assert(old.hook.status=='watching_hover')
        if not seen and new.hook.status=='watching_hover' then seen=i end
    end
    assert(seen and seen<=29,'flight seen after '..tostring(seen)..' frames')
    put(moved,'\0\0\1\0\0');put(input+8,f(0));move(1)
    print('PASS: a flight right after a registry move is seen at the next full check ('..seen..' frames late here, at most 29)')
end

-- No new trace start that keeps aborting. The guard calls the loader's after
-- under pcall, so a root trace started at its entry aborts where it returns
-- ("NYI: return to lower frame"), and report built a closure (UCLO before its
-- early returns): both retry on every frame and take LuaJIT's 64 penalty
-- slots. after runs interpreted, report has no closure, and neither the gate
-- (M.idle) nor the loader starts a root trace that aborts. Control: the v1.8
-- loader with the same patch does. Starts in older helpers (for example the
-- key compare's loop) are left to LuaJIT's blacklisting, as in v1.8.
do
    if not (jit and jit.attach and jit.status()) then return end
    local util=require('jit.util')
    local function aborts(loader_path)
        local s=side(source..'/hover_data.lua',loader_path)
        local idle_line=util.funcinfo(s.patch.idle).linedefined
        local function drive(n,row)
            put(0x46000005,row)
            for i=1,n do put(input+8,f(i%40<20 and 0 or .02));s.tick()end
        end
        jit.off(drive);jit.off(s.tick) -- lint-ok: R5 test only: the driver stands in for the game's C caller
        move(1);put(mode+0x40,u(2));put(0x42000000+48+12,u(524));ent(0x44000000,HOVER,524,generation,true)
        put(pm+0x84,u(2)..u(2))
        -- start: (tr, func, pc, parent trace); abort: (tr, ...). A side trace
        -- retries its exit only a few times (tryside), so roots are counted.
        local starts,bad,where={},0,{}
        local function on_trace(what,tr,func,_,parent)
            if what=='start' then
                local info=util.funcinfo(func)
                starts[tr]=(parent or 0)==0 and {source=tostring(info.source):match('[^/\\]*$'),line=info.linedefined} or nil
            elseif what=='abort' and starts[tr] then
                local start=starts[tr]
                if start.source=='archive_loader.lua' or (start.source=='hover_data.lua' and start.line==idle_line) then
                    bad=bad+1;where[#where+1]=start.source..':'..start.line
                end
            end
        end
        jit.attach(on_trace,'trace') -- lint-ok: R5 test only: counts trace aborts
        drive(1500,'\0\0\1\0\0') -- hover pack worn, idle
        drive(1500,'\1\0\1\0\1') -- flight with presses
        put(mode+0x40,u(0));drive(1500,'\0\0\1\0\0') -- outside a mission
        jit.attach(on_trace) -- lint-ok: R5 test only: detaches the handler above
        put(mode+0x40,u(2))
        return bad,table.concat(where,' ',1,math.min(#where,8))
    end
    local control,old_where=aborts(tests..'reference/archive_loader.lua')
    local count,new_where=aborts(source..'/archive_loader.lua')
    assert(control>0,'control: the v1.8 loader did not abort, so this test proves nothing')
    assert(count==0,count..' aborting root starts in the loader or the gate: '..new_where)
    print('PASS: the loader and the idle gate start no root trace that aborts (the v1.8 loader: '..control..', at '..old_where..')')
end
