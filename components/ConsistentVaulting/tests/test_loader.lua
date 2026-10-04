local source=assert(arg[1])
-- The build hands the loader bingus_runtime.lua (its update guard) as well.
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local function environment(loader)
    local env=setmetatable({print=function()end,os={getenv=function()end},CowboyBingusModLoader=loader},{__index=_G})
    env._G=env
    env.update=function(...)return ... end
    env.shutdown=function(...)return ... end
    return env
end
local calls,restores=0,0
local api={module=function(n)return n and 1 or 2 end,module_hash=function(n)return tostring(n) end}
local patch={apply=function(_,_,_,s)calls=calls+1;s.pending={};return true,'observing',true end,
    restore=function()restores=restores+1;return true end}
local function install(env,adapter)
    local loader=setfenv(assert(loadfile(source..'/archive_loader.lua'))(),env)
    loader(adapter or function()return api end,patch,{revision='test',game_sha256='1',exe_sha256='2'},runtime)
end
for _,loader in ipairs({{api=1,version=6},{api=2,version=5},{api=2,version=6},{api=99,version=100}}) do
    local env=environment(loader);local before=calls
    install(env);local a,b,c=env.update(1,nil,3)
    assert(a==1 and b==nil and c==3 and calls==before+2 and env.ConsistentVaulting.active)
    env.shutdown()
end
for _,loader in ipairs({false,{}, {api=1,version=0},{api=1,version=4},{api=0,version=5},
    {api=2,version=4},{api='1',version=5},{api=1,version='5'},{api=1}}) do
    local env=environment(loader);local previous=env.update
    install(env);assert(env.update==previous and not env.ConsistentVaulting.active)
    assert(env.ConsistentVaulting.status:find('Bingus Shared Loader',1,true))
end
calls,restores=0,0
local env=environment({api=1,version=5});install(env)
local a,b,c=env.update('one',nil,'three')
assert(a=='one' and b==nil and c=='three' and calls==2)
assert(select('#',env.update('one',nil,'three'))==3)
local previous=env.update;install(env);assert(env.update==previous)
a,b,c=env.shutdown(1,nil,3);assert(a==1 and b==nil and c==3 and restores==1)
local before=calls;env.update();assert(calls==before)
env=environment({api=1,version=5});previous=env.update
install(env,function()error('unavailable')end);assert(env.update==previous)
env=environment({api=1,version=5});env.update=function()error('original update failure')end
install(env);local before_restore=restores
-- The error passes through; the next update restores once and pauses the mod.
local succeeded,reason=pcall(env.update)
assert(not succeeded and tostring(reason):find('original update failure',1,true) and restores==before_restore)
succeeded,reason=pcall(env.update)
assert(not succeeded and tostring(reason):find('original update failure',1,true) and restores==before_restore+1)
assert(env.ConsistentVaulting.pending==nil
    and env.ConsistentVaulting.status=='ConsistentVaulting paused: the previous update failed')
env=environment({api=1,version=5})
patch.apply=function()return false,'deliberate_failure',false end
install(env);env.update();assert(env.ConsistentVaulting.status=='deliberate_failure')

-- A constant waiting status must still produce a fresh heartbeat, while
-- per-frame transitions must not write a log file every frame.
local now,logs=0,{}
api.time=function()return now end
patch.apply=function()return true,'waiting_for_vault_query',false end
env=environment({api=1,version=5})
env.CowboyBingusDiagnostics=true
env.os={getenv=function()return 'fixture' end}
env.io={open=function()
    local chunks={}
    return {write=function(_,s)chunks[#chunks+1]=s end,close=function()logs[#logs+1]=table.concat(chunks)end}
end}
env.CowboyBingusModLoader.open_log=function(name)
    assert(name=='ConsistentVaulting.log')
    return env.io.open('fixture/CowboyBingus/Helldivers2/Logs/'..name,'w')
end
install(env);assert(#logs==1)
for i=1,20 do env.update() end
assert(#logs==1 and env.ConsistentVaulting.updates==20 and env.ConsistentVaulting.polls==40)
now=2.1;env.update();assert(#logs==2 and logs[2]:find('updates=21',1,true))
assert(logs[2]:find('polls=41',1,true) and logs[2]:find('last_phase=before_update',1,true))
-- Probe evidence survives waiting states with its original time and origin.
local fixture=env.ConsistentVaulting
fixture.context_reprojections=4;fixture.reprojected_retries=2;fixture.reprojected_starts=1
fixture.step_report_retries=3;fixture.step_report_starts=2
fixture.last_retry_reason='native_context_changed_before_commit'
fixture.candidate_results={retained_query_reused=1,no_usable_assisted_candidate=2}
fixture.candidate_trace={time=1,root={1,2,3},direction={0,1,0},ground=true,
    result='no_usable_assisted_candidate',passes={ordinary={},slope={},raised={
        {slot=2,count=1,unit=11163,height=2.35,max_height=2.25,normal_z=.7852,normal_threshold=.707107,
            source_height=2.41,target_height=.4,position={1,2,5.35},result='height'}}}}
now=4.2;env.update()
assert(#logs==3 and logs[3]:find('probe_age_seconds=3.200',1,true))
assert(logs[3]:find('context_reprojections=4\n',1,true) and logs[3]:find('reprojected_retries=2\n',1,true)
    and logs[3]:find('reprojected_starts=1\n',1,true)
    and logs[3]:find('last_retry_reason=native_context_changed_before_commit\n',1,true))
assert(logs[3]:find('step_report_retries=3\n',1,true) and logs[3]:find('step_report_starts=2\n',1,true))
assert(logs[3]:find('probe_native_mover=1.000000,2.000000,3.000000',1,true))
assert(logs[3]:find('candidate_result_retained_query_reused=1',1,true))
assert(logs[3]:find('probe_raised_slot_2=count:1 unit:11163 height:2.350000 max:2.250000',1,true))
assert(logs[3]:find('result:height',1,true))
fixture.raised_trace=fixture.candidate_trace
fixture.candidate_trace={time=4,root={10,20,30},direction={0,1,0},ground=true,
    result='ordinary_candidate_retained',passes={ordinary={},slope={},raised={}}}
now=6.3;env.update()
assert(#logs==4 and logs[4]:find('probe_scope=last_raised_search',1,true))
assert(logs[4]:find('probe_native_mover=1.000000,2.000000,3.000000',1,true))
env.shutdown();assert(#logs==5 and logs[5]:find('stopped',1,true))
-- Every restore uses the unified cleanup, including after an apply exception
-- once the assistance module has acquired a lease. An exception restores at
-- each of the frame's two checks (the second runs from a fresh start); the
-- others restore once.
for _,failure in ipairs({'shutdown','apply_exception','apply_rejection','update_exception'}) do
    local cleaned=0
    patch.stop=function(_,_,_,s)cleaned=cleaned+1;s.slope_lease=nil;s.pending=nil;return true end
    patch.apply=function(_,_,_,s)
        s.slope_lease={};s.pending={}
        if failure=='apply_exception' then error('slope fixture failure') end
        if failure=='apply_rejection' then return false,'slope fixture rejected',false end
        return true,'observing',true
    end
    env=environment({api=2,version=6})
    if failure=='update_exception' then env.update=function()error('native update fixture failure')end end
    install(env);pcall(env.update)
    -- An update exception is seen, and cleaned up, by the next update.
    if failure=='update_exception' then pcall(env.update) end
    if failure=='shutdown' then env.shutdown() end
    assert(cleaned==(failure=='apply_exception' and 2 or 1) and env.ConsistentVaulting.slope_lease==nil
        and env.ConsistentVaulting.pending==nil,failure)
end
print('PASS: loader version/build gates, duplicate load, update/shutdown tuples, failure isolation and throttled heartbeat')

-- Checks per frame: one before the game's update, and one after it only while
-- the patch reports work in progress (state.busy); unset means always. Work
-- found right after a skipped check gets that check at once, before the update.
for _,busy in ipairs({false,true}) do
    local polls=0
    patch.apply=function(_,_,_,s) polls=polls+1;s.busy=busy;return true,'waiting_for_vault_query',false end
    env=environment({api=1,version=6});install(env)
    for _=1,10 do env.update() end
    assert(polls==(busy and 20 or 10) and env.ConsistentVaulting.polls==polls,'checks per frame')
    env.shutdown()
end
do
    local polls,phases,busy=0,{},false
    patch.apply=function(_,_,_,s) polls=polls+1;phases[#phases+1]=s.phase;s.busy=busy;return true,'observing',busy end
    env=environment({api=1,version=6});install(env)
    env.update();env.update();assert(polls==2,'idle frames check once')
    busy=true;env.update()
    assert(polls==5 and phases[3]=='before_update' and phases[4]=='before_update' and phases[5]=='after_update',
        'a start after a skipped check runs that check before the update')
    env.update();assert(polls==7,'busy frames check twice')
    busy=false;env.update();assert(polls==8,'an idle check skips the check after the update')
    env.update();assert(polls==9)
    env.shutdown()
end
print('PASS: one check per frame while idle, a second after the game update only while busy, the skipped one replayed when work starts')

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
    local patch={interval=1/30,apply=function()return true,'waiting_for_mission',false end,
        profiler={new=function()profiles=profiles+1;return {}end},stop=function()return true end,cleanup=function()return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),e)()(function()return api end,patch,
        {revision='fixture',game_sha256='hash',exe_sha256='hash'},runtime)
    local startup=opens
    for i=1,600 do now=i/60;local a,b,c=e.update(1/60);assert(a==1 and b==nil and c==3)end
    assert(diagnostics and opens>startup or not diagnostics and opens==startup,'routine log writes require opt-in')

    e.shutdown();assert(opens>startup,'shutdown report remains available')
end
print('PASS: silent default, opt-in diagnostics, shutdown report and callback returns')

-- The update chain is runtime.guard's. An error raised by the game's update is
-- not this mod's: it reaches the caller unchanged, its traceback starts where
-- it was raised and an error object keeps its identity. The next update
-- restores the mod's changes and pauses it; every update is still forwarded
-- with all values. Once the updates below have returned on 60 frames in a row,
-- the mod resumes from a fresh start.
local raised_at
local function vanilla_update_failure(err)
    raised_at=debug.getinfo(1,'Sl');error(err)
end
local function scenario()
    local f={memory='original',printed={},forwarded=0,shutdowns=0,applies=0,restores=0}
    local e=setmetatable({os={getenv=function()end}},{__index=_G});e._G=e
    e.print=function(line)f.printed[#f.printed+1]=line end
    e.CowboyBingusModLoader={api=1,version=6}
    e.update=function(...)
        f.forwarded=f.forwarded+1
        if f.fail then vanilla_update_failure(f.fail) end
        return ...
    end
    e.shutdown=function(...)f.shutdowns=f.shutdowns+1;return ... end
    -- apply writes memory; stop restores it, as the production patch does.
    -- apply_error raises in every check, or only in checks of error_phase.
    f.patch={apply=function(_,_,_,s)
        f.applies=f.applies+1
        if f.apply_error and (not f.error_phase or s.phase==f.error_phase) then error(f.apply_error,0) end
        if f.refuse then return false,f.refuse,false end
        f.memory='patched';s.pending={};return true,'observing',true
    end,stop=function(_,_,_,s)
        f.restores=f.restores+1
        if f.restore_error then error(f.restore_error) end
        f.memory='original';s.pending=nil;return true
    end}
    local a={module=function(n)return n and 1 or 2 end,module_hash=function(n)return tostring(n)end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),e)()(function()return a end,f.patch,
        {revision='fixture',game_sha256='1',exe_sha256='2'},runtime)
    function f.reports(status)
        local n=0
        for _,line in ipairs(f.printed) do if line=='[ConsistentVaulting] fixture: '..status then n=n+1 end end
        return n
    end
    function f.guard() return e.BingusRuntime.statuses.ConsistentVaulting end
    return e,f
end
local PAUSED,RESUMED='ConsistentVaulting paused: the previous update failed','ConsistentVaulting resumed after 60 clean frames'
do
    local e,f=scenario()
    local a,b,c=e.update(1,nil,3);assert(a==1 and b==nil and c==3 and f.memory=='patched' and f.applies==2)
    f.fail='vanilla update failure'
    local ok,trace=xpcall(e.update,debug.traceback,1,nil,3)
    assert(not ok and trace:find('vanilla update failure',1,true),trace)
    assert(trace:find('\n\t'..raised_at.short_src..':'..raised_at.currentline..": in function 'vanilla_update_failure'",1,true),
        'traceback must start where the update raised:\n'..trace)
    -- Nothing is handled while the error passes through.
    assert(f.memory=='patched' and e.ConsistentVaulting.status=='observing' and f.reports(PAUSED)==0)
    local object={};f.fail=object
    local raised,err=pcall(e.update,1,nil,3)
    assert(not raised and err==object,'an error object keeps its identity')
    -- That next update restored and paused the mod before forwarding.
    assert(f.memory=='original' and f.restores==1 and f.applies==3 and f.forwarded==3 and not e.ConsistentVaulting.active)
    assert(e.ConsistentVaulting.status==PAUSED and f.reports(PAUSED)==1 and f.guard().state=='paused: the previous update failed')
    -- Paused: no check, everything forwarded. The update that raised the object
    -- is seen by the next update, so the 60 clean frames start after it.
    f.fail=false
    for i=1,30 do
        assert(select('#',e.update('one',nil,'three'))==3)
        a,b,c=e.update(i,nil,nil);assert(a==i and b==nil and c==nil)
    end
    assert(f.forwarded==63 and f.applies==3 and f.restores==1 and f.memory=='original' and f.reports(RESUMED)==0)
    e.update()
    assert(f.applies==5 and f.memory=='patched' and f.reports(RESUMED)==1 and f.reports(PAUSED)==1)
    assert(e.ConsistentVaulting.status=='observing' and e.ConsistentVaulting.active)
    local status=f.guard()
    assert(status.state=='running' and status.pauses==1 and status.lower_errors==2 and status.first_failure==nil)
    a,b,c=e.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    -- A pause is not a failure of this mod.
    assert(e.ConsistentVaulting.status=='stopped' and f.memory=='original' and f.guard().state=='stopped')
end
-- A pause resets the mod to a fresh start: the press window, the input edge,
-- the retry interval and work in progress are dropped with the restore.
do
    local e,f=scenario()
    e.update()
    local s=e.ConsistentVaulting
    s.assist_intent={};s.slope_down=false;s.last_retry_at=1;s.avatar={};s.busy=true
    f.fail='vanilla update failure';pcall(e.update);f.fail=false;e.update()
    assert(s.assist_intent==nil and s.slope_down==nil and s.last_retry_at==nil and s.avatar==nil and s.busy==nil)
    assert(s.pending==nil and not s.active and f.memory=='original')
end
-- 8 errors below this mod in a burst stop it: restored at the pause and once
-- more by the stop.
do
    local e,f=scenario();f.fail='vanilla update failure'
    -- The first frame's check runs; the update that raises skips the check after it.
    for frame=1,9 do assert(not pcall(e.update)) end
    assert(f.applies==1 and f.restores==2 and f.memory=='original')
    assert(e.ConsistentVaulting.status=='stopped after 8 failed updates below this mod')
    assert(f.reports('ConsistentVaulting stopped: stopped after 8 failed updates below this mod')==1 and f.reports(PAUSED)==1)
    f.fail=false;for _=1,100 do e.update() end;assert(f.applies==1 and f.restores==2)
    e.shutdown()
    assert(f.restores==2 and f.guard().state=='stopped after: stopped after 8 failed updates below this mod')
end
print('PASS: update errors pass through unchanged, the next update restores and pauses, the mod resumes after 60 clean frames, 8 errors below stop it')

-- The mod's own errors: each restores and starts fresh, then counts. 8 in a
-- burst stop the mod; a burst ends after 3600 error-free frames, so rare errors
-- never add up. One log line per burst.
do
    local e,f=scenario();f.apply_error='apply fixture failure';f.error_phase='before_update'
    local ERROR='ConsistentVaulting error: apply fixture failure'
    for frame=1,7 do
        local a,b,c=e.update(frame,nil,3);assert(a==frame and b==nil and c==3)
        -- The check after the update runs from a fresh start and succeeds.
        assert(f.memory=='patched' and f.restores==frame)
    end
    assert(f.applies==14 and f.guard().errors==7 and f.reports(ERROR)==1 and f.guard().state=='running')
    f.apply_error=nil
    for _=1,3600 do e.update() end
    assert(f.guard().errors==0 and f.restores==7)
    f.apply_error='apply fixture failure'
    for _=1,7 do e.update() end
    assert(f.guard().errors==7 and f.reports(ERROR)==2 and f.guard().state=='running' and f.restores==14)
    e.update()
    -- The 8th of the burst: restored for the error, then once more by the stop.
    assert(f.restores==16 and f.memory=='original')
    local reason='stopped after 8 errors: apply fixture failure'
    assert(e.ConsistentVaulting.status==reason and f.reports('ConsistentVaulting stopped: '..reason)==1)
    local applies=f.applies;f.apply_error=nil
    for _=1,10 do e.update() end;assert(f.applies==applies)
    e.shutdown();assert(f.guard().state=='stopped after: '..reason and f.restores==16)
end
print('PASS: own errors restore and start fresh, 8 in a burst stop the mod, bursts end after 3600 clean frames with one log line each')

-- The first failure survives shutdown, including an update that raised just
-- before it; plain 'stopped' only when nothing failed. After a stop its own
-- restore and report have run, and the guard keeps 'stopped after: <first failure>'.
do
    local e,f=scenario();e.update();f.fail='vanilla update failure';assert(not pcall(e.update))
    assert(f.memory=='patched');e.shutdown()
    assert(f.memory=='original' and e.ConsistentVaulting.status=='stopped after: the previous update failed')
    assert(f.guard().state=='stopped after: the previous update failed')
    e,f=scenario();f.refuse='deliberate_failure';e.update()
    assert(e.ConsistentVaulting.status=='deliberate_failure' and f.restores==1 and f.applies==1)
    assert(f.reports('ConsistentVaulting stopped: deliberate_failure')==1 and f.reports('deliberate_failure')==1)
    e.shutdown()
    assert(f.restores==1 and e.ConsistentVaulting.status=='deliberate_failure')
    assert(f.guard().state=='stopped after: deliberate_failure')
    e,f=scenario();e.update();e.shutdown();assert(e.ConsistentVaulting.status=='stopped' and f.memory=='original')
    assert(f.guard().state=='stopped')
end
-- Cleanup errors never reach the game: the update before which apply failed
-- still runs, a raising cleanup at shutdown still forwards it, and a pause
-- whose restore fails stops the mod.
do
    local e,f=scenario();f.apply_error='apply fixture failure';f.restore_error='restore fixture failure'
    local a,b,c=e.update(1,nil,3);assert(a==1 and b==nil and c==3 and f.forwarded==1)
    -- The restore after the error failed: the mod stops, and its stop tries again.
    assert(e.ConsistentVaulting.status=='local_restore_failed' and f.restores==2 and f.applies==1)
    a,b,c=e.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    assert(f.guard().state=='stopped after: apply fixture failure')
    e,f=scenario();e.update();f.restore_error='restore fixture failure'
    a,b,c=e.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    assert(e.ConsistentVaulting.status=='local_restore_failed')
    e,f=scenario();e.update();f.fail='vanilla update failure';f.restore_error='restore fixture failure'
    assert(not pcall(e.update));assert(not pcall(e.update))
    assert(e.ConsistentVaulting.status=='local_restore_failed' and f.restores==2)
    assert(f.guard().first_failure=='pause failed: local_restore_failed' and not e.ConsistentVaulting.active)
    f.fail=false;f.restore_error=nil;for _=1,100 do e.update() end;assert(f.applies==3)
end
print('PASS: the first failure survives shutdown, refusals stop the mod, cleanup errors stay contained')
