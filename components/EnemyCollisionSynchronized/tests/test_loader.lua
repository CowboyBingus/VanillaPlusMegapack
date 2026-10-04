local source=assert(arg[1])
-- The loader takes the runtime core (bingus_runtime.lua, loaded here into the
-- test's environment) and the memory module. Its build check is the memory
-- api's verify_build; the fake below answers it from the test's fake modules
-- and hashes, in the runtime's words.
local function fake_memory(api)
    return {new=function(runtime)
        runtime.shared()
        return {verify_build=function(build)
            local exe,game=api.module(nil),api.module('game.dll')
            if not exe or not game then return false,'game modules unavailable' end
            if api.module_hash(exe)~=build.exe_sha256 or api.module_hash(game)~=build.game_sha256 then
                return false,'unsupported game build'
            end
            return true
        end}
    end}
end
local function loader_in(env,api)
    local install=setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()
    local runtime=setfenv(assert(loadfile(source..'/bingus_runtime.lua')),env)()
    return function(create_api,patch,build) return install(create_api,patch,build,runtime,fake_memory(api)) end
end
local function test(kind)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    env.CowboyBingusModLoader={api=1,version=kind=='old' and 8 or 9}
    local now,calls,order,resets=0,0,{},0
    env.update=function(...)order[#order+1]='game';if kind=='game_error' then error('game error') end;return 1,nil,3 end
    env.shutdown=function()return 4,nil,6 end
    env.CowboyBingusDiagnostics=true -- the profiler's failure isolation is tested here
    local original=env.update
    local api={time=function()return now end,module=function(n)return n and 1 or 2 end,
        module_hash=function(n)return kind=='build' and 'wrong' or n==1 and 'game' or 'exe' end,
        read=function()return 'original' end,
        bind=function()if kind=='binding' then error('wrong physics API') end;return {} end}
    local original_read=api.read
    local patch={interval=1/30,apply=function(a,g,e,state)
        assert(a==api and g==1 and e==2);calls=calls+1;order[#order+1]='repair'
        if kind=='transient' and calls==1 then error('manager changed') end
        return true,'ready',true
    end,reset=function()resets=resets+1 end}
    patch.profiler=setfenv(assert(loadfile(source..'/profiler.lua')),env)()
    if kind:match('^profiler_') then
        local create=patch.profiler.new
        patch.profiler.new=function(...)
            local value=create(...)
            if kind=='profiler_setup' then error('telemetry setup failed') end
            value[kind:sub(10)]=function()error('telemetry failed')end
            return value
        end
    end
    local install=loader_in(env,api)
    install(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'})
    if kind=='old' or kind=='build' or kind=='binding' then assert(env.update==original and calls==0);return end
    local wrapped=env.update;install(function()error('duplicate')end,patch,{});assert(env.update==wrapped)
    if kind=='game_error' then
        -- The game's own error propagates; the mod pauses on the next call.
        assert(not pcall(env.update));assert(calls==0 and env.CorpseCollisionRepair.status=='waiting_for_mission')
        assert(not pcall(env.update));assert(calls==0 and env.CorpseCollisionRepair.status=='paused_after_update_error')
        assert(resets==1 and api.profiler.update_errors==1 and api.profiler.chain.count==0,'Failed updates are counted, not timed')
    else
        local a,b,c=env.update();assert(a==1 and b==nil and c==3 and calls==1)
        assert(order[1]=='game' and order[2]=='repair')
        assert(select('#',env.update())==3 and calls==1,'Duplicate frame cannot submit again')
        now=.04;env.update();assert(calls==2)
        if kind=='transient' then assert(env.CorpseCollisionRepair.retries==1 and env.CorpseCollisionRepair.active) end
        if kind:match('^profiler_') then
            assert(env.CorpseCollisionRepair.profiler_failures==1 and api.profiler==nil)
            assert(api.read==original_read and env.CorpseCollisionRepair.active,'Telemetry failure interrupted gameplay')
        end
    end
    local a,b,c=env.shutdown();assert(a==4 and b==nil and c==6)
    if kind=='game_error' then
        assert(env.CorpseCollisionRepair.status=='stopped after: stopped_after_update_error' and api.profiler.update_errors==2)
    else assert(env.CorpseCollisionRepair.status=='stopped') end
    local saved=calls;now=100;pcall(env.update);assert(calls==saved)
end
for _,kind in ipairs({'normal','old','build','binding','transient','game_error','profiler_setup',
    'profiler_begin','profiler_finish','profiler_update_started','profiler_update_finished'}) do test(kind) end
print('PASS: dependency/build/binding gates, callback order and tuples, bounded poll frequency, retry, failure isolation, duplicate loads and shutdown')

-- Diagnostics are opt-in, as build.py reports (profiler_enabled_default and
-- routine_logs_enabled_default false): only CowboyBingusDiagnostics = true,
-- set before initialization, starts the profiler and the status log writes
-- during play. Startup and shutdown always write the status log.
for _,diagnostics in ipairs({false,true,'true',1}) do
    local now,opens,created,cycles=0,0,0,0
    local e=setmetatable({print=function()end},{__index=_G});e._G=e
    e.CowboyBingusDiagnostics=diagnostics
    e.CowboyBingusModLoader={api=1,version=99,open_log=function()
        opens=opens+1;return {write=function()return true end,close=function()return true end}
    end}
    e.update=function()return 1,nil,3 end;e.shutdown=function()return 4,nil,6 end
    local api={time=function()return now end,clock=function()return now end,module=function(n)return n or 'exe'end,
        module_hash=function()return 'hash'end,bind=function()return {}end,read=function()return ''end,
        thread_cycles=function()cycles=cycles+1;return cycles end}
    local original_read=api.read
    local P=setfenv(assert(loadfile(source..'/profiler.lua')),e)()
    local create=P.new
    P.new=function(...)created=created+1;return create(...)end
    local patch={interval=1/30,apply=function()return true,'waiting_for_mission',false end,profiler=P}
    loader_in(e,api)(function()return api end,patch,{revision='fixture',game_sha256='hash',exe_sha256='hash'})
    local startup=opens
    local enabled=diagnostics==true
    assert((api.read~=original_read)==enabled,'no timed reads by default')
    if not enabled then
        -- The loader's own calls per frame, polling or not: one api.time for
        -- the poll clock. The patch's calls are pinned in test_performance.lua
        -- (this stub makes none).
        local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
        local counts=budget.wrap(api)
        now=1/120;local polled=budget.frame(counts,e.update,1/120)
        now=1/60;local quiet=budget.frame(counts,e.update,1/60)
        budget.check(polled,{time=1},'loader frame with a poll')
        budget.check(quiet,{time=1},'loader frame without a poll')
        assert(budget.describe(polled)=='time=1' and budget.describe(quiet)=='time=1','exactly one call per frame')
    end
    for i=1,600 do now=i/60;local a,b,c=e.update(1/60);assert(a==1 and b==nil and c==3)end
    assert(created==(enabled and 1 or 0) and (api.profiler~=nil)==enabled,'the profiler starts only with diagnostics')
    assert((cycles>0)==enabled,'no thread cycle queries by default')
    assert((opens>startup)==enabled,'status and performance log writes during play need diagnostics')
    local before=opens;e.shutdown();assert(opens>before,'the shutdown report is always written')
end
print('PASS: diagnostics off by default: no profiler, timed reads, thread cycle queries or log writes during play; opt-in with CowboyBingusDiagnostics = true; startup and shutdown reports kept')

-- The update chain runs through runtime.guard (bingus_runtime.lua). Errors
-- raised by the wrapped callbacks reach the caller unchanged. The mod notices a
-- failed update on the next call and pauses: it forgets what its polls learned,
-- keeps forwarding, and polls afresh after 60 clean frames; 8 errors below stop
-- it, a count that starts again after 3600 frames without one. The exception:
-- the mod's own raised polls stop it only when 8 come in a row (test e). Other
-- errors in the mod's own frame stop it after 8 in a burst (test h). The
-- guard's status keeps the first failure past shutdown.
local function pack(...)return {n=select('#',...),...}end
local function harness(apply)
    local h={now=0,applies=0,resets=0,prints={}}
    local e=setmetatable({os={getenv=function()end}},{__index=_G});e._G=e
    e.print=function(text)h.prints[#h.prints+1]=text end
    e.CowboyBingusModLoader={api=1,version=9}
    e.update=function(...)h.seen=pack(...);if h.raise then h.raise() end;return 'r1',nil,'r3' end
    e.shutdown=function(...)h.closed=pack(...);if h.raise_shutdown then h.raise_shutdown() end;return 's1',nil,'s3' end
    local api={time=function()return h.now end,module=function(n)return n and 1 or 2 end,
        module_hash=function(n)return n==1 and 'game' or 'exe' end,read=function()return '' end,bind=function()return {} end}
    local patch={interval=1/30,apply=function()
        h.applies=h.applies+1;if apply then return apply(h.applies) end;return true,'ready',true
    end,reset=function()h.resets=h.resets+1;if h.reset_error then error(h.reset_error,0) end end}
    loader_in(e,api)(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'})
    h.env,h.state,h.patch=e,e.CorpseCollisionRepair,patch
    h.guard=e.BingusRuntime.statuses.EnemyCollisionSynchronized
    function h.reported(status)
        local n=0;for _,text in ipairs(h.prints) do if text=='[CorpseCollisionRepair] test: '..status then n=n+1 end end;return n
    end
    return h
end
do -- (a) the original error, traceback and error object reach the caller
    local function vanilla_update_raises()error('vanilla failure')end
    local h=harness();h.raise=function()vanilla_update_raises()end
    local ok,trace=xpcall(h.env.update,debug.traceback,1)
    assert(not ok and trace:find('vanilla_update_raises',1,true),'The traceback must start in the raising function')
    local _,expected=pcall(vanilla_update_raises)
    local _,message=pcall(h.env.update);assert(message==expected,'The error message must be unchanged')
    local thrown={};h.raise=function()error(thrown)end
    local _,value=pcall(h.env.update);assert(value==thrown,'The error object must keep its identity')
end
local function failing_frame(h)
    h.raise=function()error('vanilla failure')end;assert(not pcall(h.env.update));h.raise=nil
end
do -- (b) the next call pauses once, starts afresh and keeps forwarding; 60 clean frames resume it
    local h=harness()
    h.now=10;local r=pack(h.env.update(1,nil,3));assert(r.n==3 and h.applies==1 and h.state.status=='ready')
    failing_frame(h);assert(h.applies==1 and h.state.status=='ready' and h.resets==0)
    r=pack(h.env.update('x',nil,'z',nil))
    assert(r.n==3 and r[1]=='r1' and r[2]==nil and r[3]=='r3','Returns are forwarded')
    assert(h.seen.n==4 and h.seen[1]=='x' and h.seen[2]==nil and h.seen[3]=='z' and h.seen[4]==nil,'Arguments are forwarded')
    assert(h.applies==1 and h.resets==1 and h.state.status=='paused_after_update_error' and not h.state.active)
    assert(h.state.pauses==1 and h.reported('paused_after_update_error')==1,'The pause is reported once')
    for _=1,59 do r=pack(h.env.update('y'));assert(r.n==3 and h.seen[1]=='y') end
    assert(h.applies==1 and h.state.status=='paused_after_update_error','No poll until 60 updates below have returned')
    -- The clock has not moved since the last poll: only the fresh start makes this frame poll.
    h.env.update()
    assert(h.applies==2 and h.state.status=='ready' and h.state.active,'Resumed with a fresh poll')
    assert(h.reported('resumed_after_60_clean_frames')==1 and h.resets==1)
    local s=pack(h.env.shutdown('q',nil))
    assert(s.n==3 and s[1]=='s1' and s[2]==nil and s[3]=='s3' and h.closed.n==2 and h.closed[1]=='q')
    assert(h.state.status=='stopped','A pause is not a failure of the mod')
end
do -- (b2) errors below while paused restart the 60 frames, with no second pause
    local h=harness();h.env.update()
    failing_frame(h);h.env.update();for _=1,30 do h.env.update() end
    failing_frame(h);h.env.update();for _=1,59 do h.env.update() end
    assert(h.applies==1 and h.resets==1 and h.state.pauses==1 and h.state.status=='paused_after_update_error')
    h.env.update();assert(h.applies==2 and h.state.status=='ready')
    failing_frame(h);h.env.update();h.env.shutdown()
    assert(h.resets==2 and h.state.pauses==2 and h.state.status=='stopped','Shutdown while paused keeps no failure')
end
do -- (b3) 8 errors below stop the mod; the pause work runs once
    local h=harness();h.env.update()
    for _=1,7 do failing_frame(h);h.env.update() end
    assert(h.state.status=='paused_after_update_error' and h.resets==1)
    failing_frame(h);h.env.update()
    assert(h.state.status=='stopped_after_8_update_errors' and h.resets==1 and h.applies==1)
    for _=1,100 do h.env.update() end;assert(h.applies==1,'Stopped for the session')
    assert(h.reported('paused_after_update_error')==1 and h.reported('stopped_after_8_update_errors')==1)
    -- The guard calls the stop work once: the shutdown keeps the stop's status in the
    -- mod's log; the guard's status keeps the first failure (P2).
    h.env.shutdown();assert(h.state.status=='stopped_after_8_update_errors')
    assert(h.guard.state=='stopped after: stopped after 8 failed updates below this mod')
end
do -- (b4) errors below separated by 3600 clean frames never add up
    local h=harness()
    for _=1,10 do failing_frame(h);for _=1,3600 do h.env.update() end end
    assert(h.state.pauses==10 and h.resets==10 and h.state.status=='ready' and h.state.active)
end
do -- (b5) a pause that raises stops the mod
    local h=harness();h.env.update();h.reset_error='reset failed'
    failing_frame(h);h.env.update()
    assert(h.state.status=='pause_failed: reset failed' and h.resets==1)
    for _=1,100 do h.env.update() end;assert(h.applies==1)
    h.env.shutdown();assert(h.state.status=='pause_failed: reset failed')
    assert(h.guard.state=='stopped after: pause failed: reset failed')
end
do -- (c) a failed update directly before shutdown, a refusal, and a clean session
    local h=harness();h.raise=function()error('vanilla failure')end
    assert(not pcall(h.env.update));h.raise=nil;h.env.shutdown()
    assert(h.state.status=='stopped after: stopped_after_update_error')
    assert(h.guard.state=='stopped after: the previous update failed')
    h=harness(function()return false,'unsupported_layout',false end);h.env.update();h.now=1;h.env.update()
    assert(h.applies==1 and h.state.status=='unsupported_layout')
    h.env.shutdown();assert(h.state.status=='unsupported_layout' and h.guard.state=='stopped after: unsupported_layout')
    h=harness();h.env.update();h.env.shutdown();assert(h.state.status=='stopped' and h.guard.state=='stopped')
end
do -- (d) own shutdown work that raises cannot stop the previous shutdown
    local h=harness();h.env.update();h.env.print=function()error('console closed')end
    local s=pack(h.env.shutdown('q'))
    assert(s.n==3 and s[1]=='s1' and s[3]=='s3' and h.closed.n==1 and h.closed[1]=='q')
    assert(h.state.shutdown_error:find('console closed',1,true))
    local thrown={};h=harness();h.raise_shutdown=function()error(thrown)end
    local ok,value=pcall(h.env.shutdown);assert(not ok and value==thrown,'The previous shutdown error is not handled here')
end
do -- (e) The exception to runtime.guard's bursts: the mod's own raised polls are counted in a
    --     row. They are mostly transient races with the game (units despawning in the middle of
    --     a read) whose real-play rate is unmeasured; counted in bursts (8 without 3600 clean
    --     frames between them) they could stop the mod mid-mission. A raised poll is retried, a
    --     successful poll resets the count, and 8 in a row stop the mod.
    local failing={}
    for n=1,7 do failing[n]=true end
    for n=9,16 do failing[n]=true end
    local h=harness(function(n)if failing[n] then error('snapshot changed '..n,0) end;return true,'ready',true end)
    local function poll()h.now=h.now+1;h.env.update()end
    for _=1,7 do poll() end;assert(h.state.retries==7 and h.state.status=='waiting_for_stable_data')
    poll();assert(h.state.status=='ready' and h.state.active)
    for _=9,15 do poll() end;assert(h.state.retries==14 and h.state.status=='waiting_for_stable_data')
    poll();assert(h.applies==16 and h.state.status=='stopped after: snapshot changed 9' and not h.state.active)
    assert(h.reported('waiting_for_stable_data')==0,'A retry writes no log without diagnostics')
    assert(h.reported('stopped after: snapshot changed 9')==1)
    poll();assert(h.applies==16,'Stopped for the session')
    h.env.shutdown();assert(h.state.status=='stopped after: snapshot changed 9')
end
do -- (e2) runs of 7 raised polls, each ended by a success, never add up, however close together
    local h=harness(function(n)if n%8~=0 then error('unit despawned '..n,0) end;return true,'ready',true end)
    for _=1,800 do h.now=h.now+1;h.env.update() end
    assert(h.applies==800 and h.state.retries==700 and h.state.status=='ready' and h.state.active)
end
do -- (e3) a pause keeps the count: raised polls on either side of it are still in a row
    local h=harness(function(n)error('snapshot changed '..n,0)end)
    for _=1,4 do h.now=h.now+1;h.env.update() end
    failing_frame(h);h.env.update();for _=1,59 do h.env.update() end
    assert(h.state.status=='paused_after_update_error' and h.applies==4)
    for _=1,3 do h.now=h.now+1;h.env.update() end
    assert(h.applies==7 and h.state.status=='waiting_for_stable_data')
    h.now=h.now+1;h.env.update()
    assert(h.applies==8 and h.state.status=='stopped after: snapshot changed 1')
end
do -- (h) an error in the mod's own frame outside the poll (here its poll scheduling) never
    --     reaches the game: the guard counts it, 8 in a burst stop the mod, and a burst ends
    --     after 3600 frames without one; the first error of each burst writes the status log once
    local h=harness()
    local function own_error_frame()
        h.now=h.now+1;h.patch.interval=nil
        local r=pack(pcall(h.env.update,'dt'));h.patch.interval=1/30
        assert(r[1]==true and r[2]=='r1' and r[3]==nil and r[4]=='r3','The update below still returns its values')
    end
    h.env.update()
    for _=1,7 do own_error_frame();h.now=h.now+1;h.env.update() end
    assert(h.guard.errors==7 and h.guard.state=='running' and h.state.status=='ready')
    assert(h.reported(h.guard.burst_error and 'EnemyCollisionSynchronized error: '..h.guard.burst_error)==1)
    own_error_frame()
    assert(h.guard.state:find('^stopped: stopped after 8 errors: ') and h.state.status==h.guard.state:sub(10))
    local applies=h.applies;for _=1,10 do h.now=h.now+1;h.env.update() end;assert(h.applies==applies)
    h.env.shutdown();assert(h.guard.state:find('^stopped after: stopped after 8 errors: '))
    h=harness()
    for _=1,10 do own_error_frame();for _=1,3600 do h.env.update() end end
    assert(h.guard.state=='running' and h.guard.errors==0 and h.state.status=='ready')
    assert(#h.prints==11,'One status line per burst after the startup line')
end
do -- (f) with the real patch, a pause forgets the armed motion history, stops, scan positions and
    --     cooldowns (in place), and the first poll after resuming starts a new baseline
    local M=assert(loadfile(source..'/corpse_data.lua'))(dofile(source..'/corpse_profiles.lua'))
    local production=dofile(source..'/windows_api.lua')()
    local api={address=production.address,distance=production.distance,pointer=production.pointer,
        read=production.read,view=production.view,view_read=production.view_read,clock=function()return 0 end}
    local _,g,e,scene_state,f=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'perf_scene.lua')(M,api,0,1,1)
    api.module=function(name)return name and g or e end
    api.module_hash=function(m)return m==g and 'game' or 'exe' end
    api.bind=function()return scene_state.native end
    local env=setmetatable({print=function()end},{__index=_G});env._G=env
    env.CowboyBingusModLoader={api=1,version=17}
    local raise
    env.update=function()if raise then error('vanilla failure') end end
    loader_in(env,api)(function()return api end,M,{revision='test',game_sha256='game',exe_sha256='exe'})
    local state,now,ragdoll=env.CorpseCollisionRepair,0,f.units[1]
    local function frame()now=now+.034;f.tick(now);env.update()end
    f.matrix(f.bodies[f.units[2]][16],2)
    for _=1,60 do frame() end
    local history=state.fling_history
    assert(history[ragdoll] and history[ragdoll].armed and next(state.reposed) and next(state.cursors),'Armed before')
    raise=true;assert(not pcall(frame));raise=nil;frame()
    assert(state.status=='paused_after_update_error' and state.fling_history==history and next(history)==nil
        and next(state.fling_stopped)==nil and next(state.cursors)==nil and next(state.reposed)==nil,'Everything forgotten')
    for _=1,59 do frame() end;assert(next(history)==nil,'No poll while paused')
    frame();assert(state.status=='ready' and history[ragdoll] and not history[ragdoll].armed,'A new baseline')
end
do -- (g) with the real patch through 30 s of a busy mission (realignments, a verified stop,
    --     raised polls that are retried): without diagnostics no status or performance log
    --     line and no console line during play, only at startup and shutdown; with them,
    --     the status log at most every 2 s and the performance log every 10 s
    for _,diagnostics in ipairs({false,true}) do
        local M=assert(loadfile(source..'/corpse_data.lua'))(dofile(source..'/corpse_profiles.lua'))
        local production=dofile(source..'/windows_api.lua')()
        local api={address=production.address,distance=production.distance,pointer=production.pointer,
            read=production.read,view=production.view,view_read=production.view_read,clock=function()return 0 end}
        local _,g,e,scene_state,f=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'perf_scene.lua')(M,api,4,2,2)
        api.module=function(name)return name and g or e end
        api.module_hash=function(m)return m==g and 'game' or 'exe' end
        api.bind=function()return scene_state.native end
        api.clock=api.time -- the scene's clock: the profiler's 10 s output interval
        -- Reads of the ragdoll manager's entity list fail while failing is set: the poll raises.
        local ffi=require('ffi')
        local entities=ffi.cast('uint8_t **',ffi.cast('uint8_t **',g+0x3326948)[0]+56)[0]
        local failing,read=false,api.read
        api.read=function(address,size) if failing and address==entities then return nil end;return read(address,size) end
        api.view_read=api.read
        local logs,prints={},0
        local env=setmetatable({print=function()prints=prints+1 end},{__index=_G});env._G=env
        env.CowboyBingusDiagnostics=diagnostics
        env.CowboyBingusModLoader={api=1,version=17,open_log=function(name)
            logs[name]=(logs[name] or 0)+1;return {write=function()return true end,close=function()return true end}
        end}
        env.update=function()end;env.shutdown=function()end
        M.profiler=setfenv(assert(loadfile(source..'/profiler.lua')),env)() -- as the module wrapper does
        loader_in(env,api)(function()return api end,M,{revision='test',game_sha256='game',exe_sha256='exe'})
        local state=env.CorpseCollisionRepair
        local status_log,performance_log='CorpseCollisionRepair.log','EnemyCollisionSynchronized-Performance.log'
        assert(logs[status_log]==1 and prints==1 and not logs[performance_log],'The startup report')
        logs[status_log],prints=0,0
        local now=0
        for frame=1,1800 do
            if frame%120==0 then f.matrix(f.bodies[f.units[3]][16],2+frame%7) end
            if frame==600 then for _,body in ipairs(f.bodies[f.units[1]]) do f.matrix(body,3) end end
            failing=frame>=900 and frame<906
            now=now+1/60;f.tick(now);env.update()
        end
        assert(state.realignments>0 and state.fling_stops_verified==1 and state.retries==3 and state.status=='ready')
        if diagnostics then
            assert(logs[status_log]>=10 and logs[status_log]<=16,'Status log at most every 2 s: '..logs[status_log])
            assert(logs[performance_log]>=2 and logs[performance_log]<=4,'Performance log every 10 s: '..logs[performance_log])
        else
            assert(next(logs,next(logs))==nil and logs[status_log]==0 and prints==0,'No log or console line during play')
        end
        env.shutdown()
        assert(logs[status_log]>=1 and prints==1,'The shutdown report')
    end
end
print('PASS: original update errors, tracebacks and error objects propagate; an error below pauses once, starts afresh with full forwarding and resumes after 60 clean frames; 8 errors below in a burst stop, a burst ends after 3600 clean frames; own raised polls stop only 8 in a row, a pause keeps that count; other own errors stop only 8 in a burst and never reach the game; first failure kept at shutdown; protected own shutdown; a pause forgets what the real patch learned; in a busy mission no log or console line during play without diagnostics')
