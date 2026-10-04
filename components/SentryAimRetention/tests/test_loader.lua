local source=assert(arg[1])
-- As in the build: the vendored runtime is handed to the loader for its update guard.
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local function guard_status(env)return env.BingusRuntime.statuses.SentryAimRetention end
-- The fake apis get the runtime's own build check (bingus_memory.lua), run over
-- their fake modules and module hashes.
local memory_file=assert(loadfile(source..'/bingus_memory.lua'))()
local function with_build_check(api)
    local memory=memory_file.new(runtime)
    memory.module,memory.module_hash=api.module,api.module_hash
    api.verify_build=memory.verify_build
    return api
end
local function test(kind,loader,rejected)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    if loader==nil then loader={api=1,version=kind=='old_loader' and 6 or 7} end
    env.CowboyBingusModLoader=loader
    local calls,restores=0,0
    env.update=function(...)
        if kind=='update_error' then error('original update error') end
        return 1,nil,3
    end
    env.shutdown=function(...)return 4,nil,6 end
    local original=env.update
    local api=with_build_check({module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end})
    local patch={apply=function(a,g,e,state)
        -- An engaged sentry: the loader repeats the check after the game update.
        assert(a==api and g==1 and e==2);calls=calls+1;state.pending={};state.engaged=true
        if kind=='patch_error' then error('patch error') end
        if kind=='patch_failure' then return false,'failed',false end
        if kind=='initializing' and calls<=4 then state.pending=nil;return true,'waiting_for_mission_global_276c3d0',false end
        return true,'ready',true
    end,stop=function(a,g,e,state)restores=restores+1;return true end}
    local install=setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()
    install(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},runtime)
    if kind=='old_loader' or rejected then
        assert(env.update==original and calls==0 and not env.SentryAimRetention.active)
        assert(env.SentryAimRetention.status:find('Bingus Shared Loader',1,true))
        return
    end
    local update=env.update
    install(function()error('duplicate load')end,patch,{},runtime)
    assert(env.update==update)
    local state=env.SentryAimRetention
    if kind=='update_error' then
        -- The game's own error propagates. The next call restores and pauses the
        -- mod; 8 failed updates below it stop it.
        assert(not pcall(env.update));assert(restores==0 and calls==1)
        assert(not pcall(env.update));assert(restores==1 and calls==1)
        assert(state.status=='paused_after_update_error' and not state.active)
        for _=3,9 do assert(not pcall(env.update)) end
        assert(restores==2 and calls==1 and state.status=='stopped after 8 failed updates below this mod',state.status)
    elseif kind=='patch_error' or kind=='patch_failure' then
        -- Each own error restores everything and starts afresh on the next
        -- frame; the 8th error of a burst stops the mod.
        for n=1,7 do
            local a,b,c=env.update();assert(a==1 and b==nil and c==3 and calls==n and restores==n)
        end
        env.update();assert(calls==8 and restores==9)
        env.update();assert(calls==8 and restores==9)
    else
        local a,b,c=env.update();assert(a==1 and b==nil and c==3)
        if kind=='normal' then assert(calls==2 and select('#',env.update())==3)
        elseif kind=='initializing' then
            assert(calls==2 and not state.active)
            env.update();assert(calls==4 and not state.active)
            env.update();assert(calls==6 and state.active)
        end
    end
    local a,b,c=env.shutdown();assert(a==4 and b==nil and c==6)
    local status=state.status
    if kind=='update_error' then
        assert(status=='stopped after 8 failed updates below this mod' and restores==2)
        assert(guard_status(env).state=='stopped after: stopped after 8 failed updates below this mod')
    elseif kind=='patch_error' then
        assert(status:find('^stopped after 8 errors: .*patch error$'),status)
        assert(guard_status(env).state:find('^stopped after: stopped after 8 errors: .*patch error$'))
    elseif kind=='patch_failure' then
        assert(status=='stopped after 8 errors: failed' and guard_status(env).state=='stopped after: stopped after 8 errors: failed')
    else assert(status=='stopped' and guard_status(env).state=='stopped') end
end
for _,kind in ipairs({'normal','initializing','old_loader','update_error','patch_error','patch_failure'}) do test(kind)end
for _,loader in ipairs({{api=1,version=7},{api=2,version=7},{api=2,version=7},{api=99,version=100}}) do
    test('normal',loader)
end
for _,loader in ipairs({false,{}, {api=0,version=6},{api=2,version=6},
    {api='1',version=6},{api=1,version='6'},{api=1}}) do
    test('normal',loader,true)
end
print('PASS: minimum/newer loader and API gates, duplicate loads, callback tuples, shutdown, update exceptions and failure isolation')

-- Routine gameplay must not write diagnostics unless explicitly enabled.
for _,diagnostics in ipairs({false,true})do
    local now,opens,profiles=0,0,0
    local e=setmetatable({print=function()end},{__index=_G});e._G=e
    e.CowboyBingusDiagnostics=diagnostics
    e.CowboyBingusModLoader={api=1,version=99,open_log=function()
        opens=opens+1;return {write=function()end,close=function()end}
    end}
    e.update=function()return 1,nil,3 end;e.shutdown=function()return 4,nil,6 end
    local api=with_build_check({time=function()return now end,module=function(n)return n or 'exe'end,
        module_hash=function()return 'hash'end,bind=function()return {}end,read=function()return ''end})
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

-- Errors raised by the wrapped callbacks reach the caller unchanged. The mod
-- notices a failed update on the next call, restores and pauses, keeps
-- forwarding, and resumes after 60 clean frames.
local function pack(...)return {n=select('#',...),...}end
local function harness(stop)
    local h={applies=0,restores=0,prints={}}
    local e=setmetatable({},{__index=_G});e._G=e
    e.print=function(text)h.prints[#h.prints+1]=text end
    e.CowboyBingusModLoader={api=1,version=7}
    e.update=function(...)h.seen=pack(...);if h.raise then h.raise() end;return 'r1',nil,'r3' end
    e.shutdown=function(...)h.closed=pack(...);if h.raise_shutdown then h.raise_shutdown() end;return 's1',nil,'s3' end
    local api=with_build_check({module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end})
    -- refuse: a reason, or a function of the apply count that returns one.
    -- A ready check reports an engaged sentry, so the check repeats after the game update.
    local patch={apply=function(_,_,_,state)
        h.applies=h.applies+1
        local refuse=h.refuse
        if type(refuse)=='function' then refuse=refuse(h.applies) end
        if refuse then return false,refuse,false end
        state.engaged=true
        return true,'ready',true
    end,stop=function()h.restores=h.restores+1;if stop then return stop() end;return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),e)()(function()return api end,patch,
        {revision='test',game_sha256='game',exe_sha256='exe'},runtime)
    h.env,h.state=e,e.SentryAimRetention
    function h.reported(status)
        local n=0;for _,text in ipairs(h.prints) do if text=='[SentryAimRetention] test: '..status then n=n+1 end end;return n
    end
    function h.guard()return guard_status(e)end
    function h.running()return h.guard().state=='running' end
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
do -- (b) the next call restores once and pauses, keeps forwarding, and resumes after 60 clean frames
    local h=harness()
    local r=pack(h.env.update(1,nil,3));assert(r.n==3 and h.applies==2 and h.state.status=='ready')
    h.raise=function()error('vanilla failure')end
    assert(not pcall(h.env.update));assert(h.applies==3 and h.restores==0 and h.state.status=='ready')
    h.raise=nil;r=pack(h.env.update('x',nil,'z',nil))
    assert(r.n==3 and r[1]=='r1' and r[2]==nil and r[3]=='r3','Returns are forwarded')
    assert(h.seen.n==4 and h.seen[1]=='x' and h.seen[2]==nil and h.seen[3]=='z' and h.seen[4]==nil,'Arguments are forwarded')
    assert(h.applies==3 and h.restores==1 and h.state.status=='paused_after_update_error' and not h.state.active)
    assert(h.reported('paused: the previous update failed')==1,'The pause is printed once')
    for _=1,59 do r=pack(h.env.update('y'));assert(r.n==3 and h.seen[1]=='y') end
    assert(h.applies==3 and h.restores==1,'No check while the updates below have not returned on 60 frames')
    h.env.update();assert(h.applies==5 and h.state.status=='ready' and h.running(),'Resumed with both checks')
    assert(h.reported('resumed after 60 clean frames')==1 and #h.prints==3,'Install, pause and resume lines only')
    -- An error below during the pause starts the 60 frames again; the restore is not repeated.
    h.raise=function()error('again')end;assert(not pcall(h.env.update));h.raise=nil
    h.env.update();assert(h.restores==2 and h.guard().pauses==2)
    for _=1,30 do h.env.update() end
    h.raise=function()error('during the pause')end;assert(not pcall(h.env.update));h.raise=nil
    for _=1,60 do h.env.update() end
    assert(h.applies==6 and h.restores==2 and h.guard().pauses==2 and not h.running())
    h.env.update();assert(h.applies==8 and h.running())
    local s=pack(h.env.shutdown('q',nil))
    assert(s.n==3 and s[1]=='s1' and s[2]==nil and s[3]=='s3' and h.closed.n==2 and h.closed[1]=='q')
    assert(h.restores==3 and h.state.status=='stopped' and h.guard().state=='stopped','A resumed session ends clean')
end
do -- (c) a failed update directly before shutdown, a failed restore, and a clean session
    local h=harness();h.raise=function()error('vanilla failure')end
    assert(not pcall(h.env.update));h.raise=nil;h.env.shutdown()
    assert(h.restores==1 and h.state.status=='stopped after: the previous update failed')
    assert(h.guard().state=='stopped after: the previous update failed')
    -- Without a full restore an own refusal stops at once; the stop tries once more.
    h=harness(function()return false end);h.refuse='failed';h.env.update()
    assert(h.applies==1 and h.restores==2 and h.state.status=='failed; restore_failed' and not h.running())
    assert(h.reported('stopped: failed')==1)
    h.env.update();assert(h.applies==1)
    h.env.shutdown();assert(h.restores==2 and h.state.status=='failed; restore_failed')
    assert(h.guard().state=='stopped after: failed','The first failure survives shutdown')
    h=harness();h.env.update();h.env.shutdown();assert(h.state.status=='stopped')
end
do -- (d) own shutdown work that raises cannot stop the previous shutdown
    local h=harness(function()error('restore raised')end);h.env.update()
    local s=pack(h.env.shutdown('q'))
    assert(s.n==3 and s[1]=='s1' and s[3]=='s3' and h.closed.n==1 and h.closed[1]=='q')
    assert(h.restores==1 and h.state.status=='restore_failed')
    h=harness();h.env.update();h.env.print=function()error('console closed')end
    s=pack(h.env.shutdown('q'));assert(s.n==3 and h.closed[1]=='q' and h.guard().stop_error:find('console closed',1,true))
    local thrown={};h=harness();h.raise_shutdown=function()error(thrown)end
    local ok,value=pcall(h.env.shutdown);assert(not ok and value==thrown,'The previous shutdown error is not handled here')
end
print('PASS: original update errors, tracebacks and error objects propagate; restore and pause on the next call with full forwarding, resume after 60 clean frames; first failure kept at shutdown; protected own shutdown')

do -- (e) own errors: each restores and starts afresh; one line per burst; a clean minute clears a burst
    local h=harness();h.env.update()
    h.refuse='failed'
    for _=1,7 do h.env.update() end
    assert(h.applies==9 and h.restores==7 and h.state.status=='failed' and h.running(),'7 errors: still running')
    assert(h.guard().errors==7 and h.reported('error: failed')==1,'One line for the burst')
    h.refuse=nil
    for _=1,3600 do h.env.update() end
    assert(h.guard().errors==0 and h.state.status=='ready','A clean minute clears the burst')
    h.refuse='failed'
    for _=1,7 do h.env.update() end
    assert(h.running() and h.guard().errors==7 and h.reported('error: failed')==2,'A second burst of 7 keeps running')
    h.env.update()
    assert(not h.running() and h.state.status=='stopped after 8 errors: failed' and h.restores==16,h.state.status)
    assert(h.reported('stopped: stopped after 8 errors: failed')==1)
    local applies=h.applies;h.env.update();assert(h.applies==applies,'Stopped for good')
    h.env.shutdown()
    assert(h.restores==16 and h.state.status=='stopped after 8 errors: failed')
    assert(h.guard().state=='stopped after: stopped after 8 errors: failed','The first failure survives shutdown')
end
do -- (f) an error in the check after the game update counts too; the next frame starts afresh
    local h=harness();h.env.update()
    h.refuse=function(n)return n==4 and 'after failed' end
    h.env.update()
    assert(h.applies==4 and h.restores==1 and h.state.status=='after failed' and h.guard().errors==1 and h.running())
    assert(h.reported('error: after failed')==1)
    h.env.update();assert(h.applies==6 and h.state.status=='ready','The next frame checks twice again')
end
do -- (g) a pause whose restore fails stops the mod at once
    local failing=false
    local h=harness(function()return not failing end);h.env.update()
    h.raise=function()error('vanilla failure')end;assert(not pcall(h.env.update));h.raise=nil
    failing=true;h.env.update()
    assert(h.restores==2 and not h.running(),'The pause and the stop each try once')
    assert(h.state.status=='pause failed: the sentry controls could not be restored; restore_failed',h.state.status)
    failing=false;h.env.shutdown()
    assert(h.restores==2 and h.guard().state=='stopped after: pause failed: the sentry controls could not be restored')
end
print('PASS: own errors restore and start afresh, one line per burst, 8 in a burst stop; failed restores stop at once')

-- The runtime's build check runs before anything is installed: another game
-- build, or a process without the game's modules, leaves the update chain alone,
-- applies nothing and prints the reason once.
for _,case in ipairs({
    {module=function(n)return n and 1 or 2 end,hash={'other','exe'},status='unsupported game build'},
    {module=function(n)return n and 1 or 2 end,hash={'game','other'},status='unsupported game build'},
    {module=function(n)if n==nil then return 2 end end,hash={'game','exe'},status='game modules unavailable'},
    {module=function(n)if n then return 1 end end,hash={'game','exe'},status='game modules unavailable'},
}) do
    local prints,applies,hashed={},0,0
    local e=setmetatable({print=function(text)prints[#prints+1]=text end},{__index=_G});e._G=e
    e.CowboyBingusModLoader={api=1,version=7}
    local original=function()return 1 end;e.update=original
    local api=with_build_check({module=case.module,module_hash=function(n)hashed=hashed+1;return case.hash[n] end})
    local patch={apply=function()applies=applies+1;return true,'ready',true end,stop=function()return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),e)()(function()return api end,patch,
        {revision='test',game_sha256='game',exe_sha256='exe'},runtime)
    local state=e.SentryAimRetention
    assert(tostring(state.status):find(': '..case.status..'$') and not state.active,tostring(state.status))
    assert(e.update==original and applies==0 and #prints==1 and prints[1]=='[SentryAimRetention] test: '..state.status)
    assert(case.status=='unsupported game build' or hashed==0,'Missing modules are never hashed')
end
print('PASS: the runtime build check refuses another game build or missing game modules before installing anything')
