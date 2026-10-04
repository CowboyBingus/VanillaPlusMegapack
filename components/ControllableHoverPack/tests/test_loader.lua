local source=assert(arg[1])
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local function environment(loader)
    local e=setmetatable({CowboyBingusModLoader=loader,print=function()end,os={getenv=function()end}}, {__index=_G})
    e._G=e;e.update=function(...)return ... end;e.shutdown=function(...)return ... end;return e
end
local calls,cleanups=0,0
local a={time=function()return 1 end,module=function(name)return name and 1 or 2 end,module_hash=function(m)return tostring(m)end}
local patch={apply=function()calls=calls+1;return 'watching_hover'end,
    cleanup=function(_,_,state)cleanups=cleanups+1;state.lease=nil;return true end}
local function install(e,api,shared)
    if shared==nil then shared=runtime end
    setfenv(assert(loadfile(source..'/archive_loader.lua'))(),e)(api or function()return a end,patch,
        {revision='test',game_sha256='1',exe_sha256='2'},shared)
end
for _,loader in ipairs({false,{}, {api=0,version=12},{api=1,version=11},{api='1',version=12}})do
    local e=environment(loader);local before=e.update;install(e);assert(e.update==before and not e.HoverPackCancel.active)
end
local e=environment({api=1,version=12});install(e);local before=e.update;install(e);assert(e.update==before)
local x,y,z=e.update(1/60,nil,3);assert(x==1/60 and y==nil and z==3 and calls==1)
assert(select('#',e.update(1/60,nil,3))==3)
local status=e.BingusRuntime.statuses.ControllableHoverPack;assert(status.installed and status.state=='running')
local n=calls;e.shutdown();e.update(1/60);assert(calls==n and e.HoverPackCancel.status=='stopped' and cleanups==1)
assert(status.state=='stopped')
-- An update below that raises passes through; the next update pauses this
-- mod and restores (the policy is tested below).
e=environment({api=1,version=12});e.update=function()error('original failed')end;install(e)
assert(not pcall(e.update,1/60) and cleanups==1 and e.HoverPackCancel.status=='waiting_for_mission')
assert(not pcall(e.update,1/60));assert(calls==n and e.HoverPackCancel.status=='paused: the previous update failed')
assert(cleanups==2)
-- An error of this mod is counted, and the mod keeps working.
e=environment({api=1,version=12});install(e);e.update(1/60);assert(e.HoverPackCancel.active and calls==n+1)
patch.apply=function()error('stale actor',0)end
e.update(1/60);assert(not e.HoverPackCancel.active and e.HoverPackCancel.status=='error: stale actor' and cleanups==2)
patch.apply=function()calls=calls+1 end;e.update(1/60);assert(calls==n+2)
e=environment({api=1,version=12});before=e.update;install(e,function()error('hash failed')end);assert(e.update==before)
-- Without bingus_runtime.lua nothing is installed, and the status says why.
e=environment({api=1,version=12});before=e.update;local before_shutdown=e.shutdown;install(e,nil,false)
assert(e.update==before and e.shutdown==before_shutdown and e.HoverPackCancel.status:find('runtime',1,true))
print('PASS: loader version/hash/runtime gates, single update boundary, return values, duplicate load, failure isolation and shutdown')

-- Routine gameplay must not write diagnostics unless explicitly enabled.
for _,diagnostics in ipairs({false,true})do
    local now,opens,profiles=0,0,0
    local e=setmetatable({print=function()end},{__index=_G});e._G=e
    e.CowboyBingusDiagnostics=diagnostics
    e.CowboyBingusModLoader={api=1,version=99,open_log=function()
        opens=opens+1;return {write=function()end,close=function()end}
    end}
    e.update=function()return 1,nil,3 end;e.shutdown=function()return 4,nil,6 end
    local api={time=function()return now end,module=function(n)return n or 'exe'end,
        module_hash=function()return 'hash'end,bind=function()return {}end,read=function()return ''end}
    local patch={interval=1/30,apply=function()return 'waiting_for_mission' end,
        profiler={new=function()profiles=profiles+1;return {}end},stop=function()return true end,cleanup=function()return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),e)()(function()return api end,patch,
        {revision='fixture',game_sha256='hash',exe_sha256='hash'},runtime)
    local startup=opens
    for i=1,600 do now=i/60;local a,b,c=e.update(1/60);assert(a==1 and b==nil and c==3)end
    assert(diagnostics and opens>startup or not diagnostics and opens==startup,'routine log writes require opt-in')

    local a,b,c=e.shutdown();assert(a==4 and b==nil and c==6 and opens>startup,'shutdown report remains available')
end
print('PASS: silent default, opt-in diagnostics, shutdown report and callback returns')

-- The update chain policy of bingus_runtime.lua's guard, through this mod.
local raised_at
local function vanilla_update_failure(err)
    raised_at=debug.getinfo(1,'Sl');error(err)
end
local function scenario()
    local f={duration='original',printed={},forwarded=0,shutdowns=0,applies=0,cleanups=0}
    local e=setmetatable({os={getenv=function()end}},{__index=_G});e._G=e
    e.print=function(line)f.printed[#f.printed+1]=line end
    e.CowboyBingusModLoader={api=1,version=12}
    e.update=function(...)
        f.forwarded=f.forwarded+1
        if f.fail then vanilla_update_failure(f.fail) end
        return ...
    end
    e.shutdown=function(...)f.shutdowns=f.shutdowns+1;return ... end
    -- apply writes the pack duration and takes a lease; cleanup restores it.
    local p={apply=function(_,_,_,s)
        f.applies=f.applies+1
        if f.apply_error then error(f.apply_error,0) end
        f.duration='cancelled';s.lease={};return 'native_descent'
    end,cleanup=function(_,_,s)
        f.cleanups=f.cleanups+1
        if f.restore_error then error(f.restore_error,0) end
        if f.restore_wait then return false,f.restore_wait end
        f.duration='original';s.lease=nil;return true
    end}
    local a={time=function()return 1 end,module=function(n)return n and 1 or 2 end,module_hash=function(m)return tostring(m)end}
    setfenv(assert(loadfile(source..'/archive_loader.lua'))(),e)(function()return a end,p,
        {revision='fixture',game_sha256='1',exe_sha256='2'},runtime)
    function f.reports(status)
        local n=0
        for _,line in ipairs(f.printed) do if line=='[ControllableHoverPack] fixture: '..status then n=n+1 end end
        return n
    end
    -- n updates that forward every value.
    function f.ticks(n)
        for _=1,n do local a,b,c=e.update(1/60,nil,3);assert(a==1/60 and b==nil and c==3)end
    end
    -- count updates below that raise (each is seen on the next update).
    function f.fail_below(count)
        for i=1,count do f.fail='vanilla update failure '..i;assert(not pcall(e.update,1/60,nil,3))end
        f.fail=false
    end
    f.guard=e.BingusRuntime.statuses.ControllableHoverPack
    return e,f
end
-- An error raised below this mod is not this mod's: it reaches the caller
-- unchanged, its traceback starts where it was raised and an error object
-- keeps its identity. The next update pauses the mod: it restores before
-- forwarding and skips the work until the updates below have returned on 60
-- frames in a row, then works again. Every update is forwarded with all values.
do
    local e,f=scenario()
    local a,b,c=e.update(1/60,nil,3);assert(a==1/60 and b==nil and c==3 and f.duration=='cancelled' and f.applies==1)
    f.fail='vanilla update failure'
    local ok,trace=xpcall(e.update,debug.traceback,1/60,nil,3)
    assert(not ok and trace:find('vanilla update failure',1,true),trace)
    assert(trace:find('\n\t'..raised_at.short_src..':'..raised_at.currentline..": in function 'vanilla_update_failure'",1,true),
        'traceback must start where the update raised:\n'..trace)
    -- Nothing is handled while the error passes through.
    assert(f.duration=='cancelled' and e.HoverPackCancel.status=='native_descent' and f.cleanups==0)
    local object={};f.fail=object
    local raised,err=pcall(e.update,1/60,nil,3)
    assert(not raised and err==object,'an error object keeps its identity')
    -- That next update paused the mod and restored before forwarding.
    assert(f.duration=='original' and f.cleanups==1 and f.applies==1 and f.forwarded==3 and not e.HoverPackCancel.active)
    assert(e.HoverPackCancel.status=='paused: the previous update failed' and f.reports('paused: the previous update failed')==1)
    -- The first of these updates sees the second failure: still one pause.
    f.fail=false;f.ticks(60)
    assert(f.applies==1 and f.cleanups==1 and f.forwarded==63 and f.reports('paused: the previous update failed')==1)
    assert(f.guard.pauses==1 and f.guard.lower_errors==2 and f.guard.state=='paused: the previous update failed')
    f.ticks(1)
    assert(f.applies==2 and f.duration=='cancelled' and f.reports('resumed after 60 clean frames')==1 and f.guard.state=='running')
    a,b,c=e.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    -- The mod recovered, so the pause is not a failure.
    assert(e.HoverPackCancel.status=='stopped' and f.duration=='original' and f.guard.state=='stopped')
end
-- 8 updates below that raise stop the mod: it restores and works no more,
-- and every update is still forwarded. The count starts again after 3600
-- frames in which the updates below returned.
do
    local e,f=scenario();f.ticks(1)
    f.fail_below(7);f.ticks(1)
    assert(f.guard.lower_errors==7 and f.guard.pauses==1 and f.duration=='original')
    f.ticks(3599);assert(f.guard.lower_errors==0 and f.guard.state=='running' and f.duration=='cancelled')
    local applies,forwarded=f.applies,f.forwarded
    f.fail_below(8);f.ticks(1)
    assert(f.guard.pauses==2 and f.reports('stopped: stopped after 8 failed updates below this mod')==1)
    assert(f.guard.state=='stopped: stopped after 8 failed updates below this mod' and f.duration=='original')
    f.ticks(100);assert(f.applies==applies and f.forwarded==forwarded+109 and f.cleanups==3)
    e.shutdown()
    assert(e.HoverPackCancel.status=='stopped after: stopped after 8 failed updates below this mod')
    assert(f.guard.state=='stopped after: stopped after 8 failed updates below this mod')
end
-- The mod's own errors: one line per burst; a count starts again after 3600
-- frames without one; 8 in a burst stop the mod, which restores and works no
-- more. The first failure survives shutdown.
do
    local e,f=scenario();f.apply_error='stale actor'
    f.ticks(7)
    assert(f.applies==7 and f.guard.errors==7 and f.reports('error: stale actor')==1 and f.guard.state=='running')
    f.apply_error=nil;f.ticks(3599);assert(f.guard.errors==7 and f.duration=='cancelled')
    f.ticks(1);assert(f.guard.errors==0)
    f.apply_error='stale actor';f.ticks(1);assert(f.guard.errors==1 and f.reports('error: stale actor')==2)
    f.ticks(6);f.apply_error=nil;f.ticks(100);assert(f.guard.errors==7 and f.cleanups==0)
    f.apply_error='last straw';f.ticks(1)
    assert(f.guard.state=='stopped: stopped after 8 errors: stale actor' and f.reports('stopped: stopped after 8 errors: stale actor')==1)
    assert(f.reports('error: last straw')==0 and f.cleanups==1 and f.duration=='original' and not e.HoverPackCancel.lease)
    local applies=f.applies;f.apply_error=nil;f.ticks(100);assert(f.applies==applies and f.cleanups==1)
    local a,b,c=e.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.cleanups==2)
    assert(e.HoverPackCancel.status=='stopped after: stopped after 8 errors: stale actor')
    assert(f.guard.state=='stopped after: stopped after 8 errors: stale actor' and f.guard.first_error=='stale actor')
end
-- An update that raised just before shutdown is the first failure; plain
-- 'stopped' only when nothing failed; 'restore_failed' when the shutdown
-- restore raises (that error never reaches the game) or returns with the
-- lease still held (logged by the status alone).
do
    local e,f=scenario();f.ticks(1);f.fail='vanilla update failure';assert(not pcall(e.update,1/60))
    assert(f.duration=='cancelled');e.shutdown()
    assert(f.duration=='original' and e.HoverPackCancel.status=='stopped after: the previous update failed')
    assert(f.guard.state=='stopped after: the previous update failed')
    e,f=scenario();f.ticks(1);e.shutdown();assert(e.HoverPackCancel.status=='stopped' and f.duration=='original')
    e,f=scenario();f.ticks(1);f.restore_error='restore fixture failure'
    local a,b,c=e.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    assert(e.HoverPackCancel.status=='restore_failed' and f.reports('restore_failed: restore fixture failure')==1)
    e,f=scenario();f.ticks(1);f.restore_wait='Hover settings unreadable';e.shutdown()
    assert(e.HoverPackCancel.status=='restore_failed' and f.duration=='cancelled' and f.cleanups==1)
    assert(f.reports('restore_failed: Hover settings unreadable')==0)
end
-- A pause whose restore fails stops the mod instead; that update is still
-- forwarded, and the restore is retried on the next updates after the stop.
do
    local e,f=scenario();f.ticks(1);f.restore_error='restore fixture failure'
    f.fail_below(1)
    local a,b,c=e.update(1/60,nil,3);assert(a==1/60 and b==nil and c==3 and f.forwarded==3)
    assert(f.guard.state=='stopped: pause failed: hover duration not restored' and f.cleanups==2)
    assert(f.reports('restore_failed: restore fixture failure')==1 and e.HoverPackCancel.lease)
    f.restore_error=nil;f.ticks(1);assert(f.cleanups==3 and f.duration=='original' and not e.HoverPackCancel.lease)
    f.ticks(10);assert(f.cleanups==3 and f.applies==1)
    e.shutdown();assert(e.HoverPackCancel.status=='stopped after: pause failed: hover duration not restored')
end
print('PASS: update errors below pass through unchanged and pause the mod (restore, resume after 60 clean frames, stop after 8); own errors counted per burst (stop after 8); the first failure survives shutdown; restore errors stay contained')

-- A mod stopped by its 8th own error (update 8) while holding a lease, with
-- the given restore (patch.cleanup). h.attempts lists the update of every
-- restore attempt; h.run(n) runs updates up to n; h.lines() counts the
-- forced status lines since the install.
local function stopped_hook(restore)
    local h={opens=0,frame=0,attempts={}}
    local e=setmetatable({print=function()end},{__index=_G});e._G=e
    e.CowboyBingusModLoader={api=1,version=99,open_log=function()
        h.opens=h.opens+1;return {write=function()end,close=function()end}
    end}
    e.update=function()return 1,nil,3 end;e.shutdown=function()end
    local api={time=function()return 0 end,module=function(n)return n or 'exe'end,module_hash=function()return 'hash'end}
    local patch={apply=function(_,_,_,state)state.lease={key=1};error('stale actor')end,
        cleanup=function(_,_,state)h.attempts[#h.attempts+1]=h.frame;return restore(state,#h.attempts)end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),e)()(function()return api end,patch,
        {revision='fixture',game_sha256='hash',exe_sha256='hash'},runtime)
    h.startup=h.opens
    function h.run(last)
        for i=h.frame+1,last do h.frame=i;local a,b,c=e.update(1/60);assert(a==1 and b==nil and c==3)end
    end
    function h.lines()return h.opens-h.startup end
    return e,h
end
-- The stop's own attempt, then the 1st, 2nd, 4th ... 512th update after it.
local SPACED={8,9,10,12,16,24,40,72,136,264,520}
local function attempted(h,expected)
    assert(#h.attempts==#expected,'restore attempts: '..#h.attempts)
    for i,at in ipairs(expected)do assert(h.attempts[i]==at,'attempt '..i..' on update '..tostring(h.attempts[i]))end
end
-- After the stop, a restore that keeps raising is tried on 10 spaced updates,
-- logged when it first raises and once when the retries end, never per frame;
-- shutdown tries once more and keeps the first failure.
do
    local e,h=stopped_hook(function()error('write failed')end)
    h.run(1100);attempted(h,SPACED)
    assert(h.lines()==4,'the error burst, the stop, the first failed restore and the end of the retries: '..h.lines())
    assert(e.HoverPackCancel.status:find('^restore_abandoned after 10 retries: .*write failed'),e.HoverPackCancel.status)
    e.shutdown()
    assert(#h.attempts==12 and h.attempts[12]==1100 and h.lines()==5)
    assert(e.HoverPackCancel.status:find('^restore_failed after: stopped after 8 errors: .*stale actor'),e.HoverPackCancel.status)
end
-- A restore that returns without settling the lease (the pack's settings
-- cannot be found) counts alike: the same 10 spaced updates, one line when
-- they end naming the reason, none per attempt and no attempt afterwards.
do
    local e,h=stopped_hook(function()return false,'Hover settings map full'end)
    h.run(1100);attempted(h,SPACED)
    assert(h.lines()==3,'the error burst, the stop and the end of the retries: '..h.lines())
    assert(e.HoverPackCancel.status=='restore_abandoned after 10 retries: Hover settings map full',e.HoverPackCancel.status)
    e.shutdown()
    assert(#h.attempts==12 and h.lines()==4)
    assert(e.HoverPackCancel.status:find('^restore_failed after: stopped after 8 errors: .*stale actor'),e.HoverPackCancel.status)
end
-- A short failure passes: the 5th attempt (update 16) settles the lease, and
-- nothing is tried or logged after it.
do
    local e,h=stopped_hook(function(state,n)
        if n<5 then return false,'Hover settings unreadable' end
        state.lease=nil;return true
    end)
    h.run(1100);attempted(h,{8,9,10,12,16})
    assert(h.lines()==2 and e.HoverPackCancel.status:find('^stopped: stopped after 8 errors: .*stale actor'),e.HoverPackCancel.status)
    e.shutdown()
    assert(#h.attempts==6 and e.HoverPackCancel.status:find('^stopped after: stopped after 8 errors: .*stale actor'),e.HoverPackCancel.status)
end
print('PASS: after a stop, a restore that raises or keeps the lease is tried on 10 spaced updates (1st to 512th), logged once and once when given up; a short failure passes')
