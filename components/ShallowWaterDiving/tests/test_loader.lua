local source=assert(arg[1])
-- The build passes the text module, the locales and the runtime to the loader.
local Text=assert(loadfile(source..'/bingus_text.lua'))()
local Runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local LOCALES={en=assert(loadfile(source..'/../locales/en.lua'))(),bundled={}}
Text.registry().steam_language='en'
-- The update guard's status, kept in BingusRuntime of the globals it wraps.
local function guard_status(env) return env.BingusRuntime.statuses.ShallowWaterDiving end
local PAUSED='paused: the previous update failed'
local function test(kind,loader,rejected)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    if loader==nil then loader=kind=='old_loader' and {api=1,version=14} or {api=1,version=17,open_log=function() end} end
    env.CowboyBingusModLoader=loader
    local calls,restores=0,0
    env.update=function(...)
        if kind=='update_error' then error('original update error') end
        return 1,nil,3
    end
    env.shutdown=function(...)return 4,nil,6 end
    local original=env.update
    local api={module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    local patch={apply=function(a,g,e,state)
        assert(a==api and g==1 and e==2);calls=calls+1;state.pending={}
        if kind=='patch_error' then error('patch error') end
        if kind=='patch_failure' then return false,'failed',false end
        if kind=='initializing' and calls<=4 then state.pending=nil;return true,'waiting_for_mission_global_276c3d0',false end
        return true,'ready',true
    end,restore=function(a,p)restores=restores+1;return true end}
    local install=setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()
    install(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES,Runtime)
    if kind=='old_loader' or rejected then
        assert(env.update==original and calls==0 and not env.ShallowWaterDive.active)
        assert(env.ShallowWaterDive.status:find('Bingus Shared Loader',1,true))
        return
    end
    local update=env.update
    install(function()error('duplicate load')end,patch,{})
    assert(env.update==update)
    if kind=='update_error' then
        -- The error passes through; the next update pauses the mod, which restores once.
        assert(not pcall(env.update) and restores==0)
        assert(not pcall(env.update) and restores==1 and env.ShallowWaterDive.status==PAUSED)
    else
        local a,b,c=env.update();assert(a==1 and b==nil and c==3)
        if kind=='normal' then assert(calls==2 and select('#',env.update())==3)
        elseif kind=='initializing' then
            -- While waiting (no lease, retry or local avatar) only the
            -- before-update boundary is checked.
            assert(calls==1 and not env.ShallowWaterDive.active)
            env.update();env.update();env.update();assert(calls==4 and not env.ShallowWaterDive.active)
            env.update();assert(calls==6 and env.ShallowWaterDive.active)
        elseif kind=='patch_failure' then
            -- A refusal stops the mod at once: it restores once and checks no more.
            assert(calls==1 and restores==1);env.update();assert(calls==1)
        else
            -- Its own errors are counted, at both boundaries while a lease is
            -- held: the 8th, on the 4th update, stops the mod, which restores once.
            assert(calls==2 and restores==0 and guard_status(env).errors==2)
            env.update();env.update();assert(calls==6 and restores==0)
            env.update();assert(calls==8 and restores==1)
            assert(env.ShallowWaterDive.status:find('^stopped after 8 errors: .*patch error'),env.ShallowWaterDive.status)
            env.update();assert(calls==8)
        end
    end
    local a,b,c=env.shutdown();assert(a==4 and b==nil and c==6)
end
for _,kind in ipairs({'normal','initializing','old_loader','update_error','patch_error','patch_failure'}) do test(kind)end
-- Feature tests only: API 1 with open_log (v14-v19 shapes; any or no version).
local ol=function() end
for _,loader in ipairs({{api=1,version=15,open_log=ol},{api=1,version=16,open_log=ol,discovery='0'},{api=1,version=17,open_log=ol,jit={}},{api=1,version=5,open_log=ol},{api=1,version='x',open_log=ol},{api=1,open_log=ol}}) do
    test('normal',loader)
end
for _,loader in ipairs({false,{},{api=0,open_log=ol},{api=2,open_log=ol},{api='1',open_log=ol},{api=1,open_log=true},
    {api=1},{api=1,version=6},{api=1,version=14},{api=99,version=100,open_log=ol}}) do
    test('normal',loader,true)
end
-- Mod Options Menu: the depth slider registers on the first update only, its
-- applied value reaches the patch and later applied changes follow. Without
-- the menu, with another API, a refused registration or a failing menu,
-- nothing reaches the game's update and the reason is kept for the log.
local function menu_test(menu)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    env.CowboyBingusModLoader={api=1,version=6,open_log=function() end};env.ModOptionsMenu=menu
    local updates=0
    env.update=function() updates=updates+1;return 1 end
    local api={module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    local depths={}
    local patch={apply=function() return true,'ready',true end,restore=function() return true end,
        MIN_WATER_DEPTH=0.20,SWIM_DEPTH=1.30,set_max_water_depth=function(d) depths[#depths+1]=d;return true end}
    local install=setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()
    install(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES,Runtime)
    assert(env.update()==1 and env.update()==1 and updates==2)
    return env.ShallowWaterDive,depths
end
do
    local registered,callbacks={},{}
    local state,depths=menu_test({api=1,
        register_option=function(id,spec) registered[#registered+1]={id,spec};return true end,
        get=function(id) assert(id=='shallow_water_diving.max_water_depth');return 0.45 end,
        on_change=function(id,fn) callbacks[#callbacks+1]=fn;return true end})
    assert(#registered==1 and registered[1][1]=='shallow_water_diving.max_water_depth')
    local spec=registered[1][2]
    assert(spec.type=='slider' and spec.min==0.20 and spec.max==1.30 and spec.step==0.05 and spec.default==0.20)
    assert(spec.mod=='Shallow Water Diving' and #spec.label<=64 and #spec.description<=400)
    assert(state.depth_option=='registered' and #depths==1 and depths[1]==0.45 and #callbacks==1)
    callbacks[1](0.9);assert(depths[2]==0.9)
    state=menu_test({api=1,register_option=function() return false,'bad spec' end})
    assert(state.depth_option=='not registered: bad spec')
    state=menu_test({api=1,register_option=function() error('menu error',0) end})
    assert(state.depth_option=='failed: menu error')
    assert(menu_test(nil).depth_option=='not installed' and menu_test({api=2}).depth_option=='not installed')
    -- Mod Options Menu v1.1 (version 2): texts are functions that follow the
    -- game's language; the numbers stay as they are.
    registered={}
    state=menu_test({api=1,version=2,
        register_option=function(id,spec) registered[#registered+1]={id,spec};return true end,
        get=function() return 0.2 end,on_change=function() return true end})
    spec=registered[1][2]
    assert(state.depth_option=='registered' and type(spec.label)=='function' and type(spec.mod)=='function')
    assert(spec.label()=='Max Dive Water Depth' and spec.mod()=='Shallow Water Diving' and spec.min==0.20)
    local zh=Text.encode(0x6700)..Text.encode(0x5927)
    Text.register({language='zh-Hans',name='test',mods={shallow_water_diving={['option.depth.label']=zh}}})
    Text.registry().game_language='zh-Hans'
    assert(spec.label()==zh and spec.mod()=='Shallow Water Diving','translated where a translation exists')
    Text.registry().game_language='en'
end
-- The registration is tried again when the menu's API table or its revision
-- changes, looked at every 30 updates and at most 8 times in all; once
-- registered (or out of attempts) the menu is not looked at again. loader
-- (default: loader v18, no capabilities) and menu are in place before the
-- mod loads.
local function menu_watch_test(loader,initial_menu)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    env.CowboyBingusModLoader=loader or {api=1,version=6,open_log=function() end};env.ModOptionsMenu=initial_menu
    env.update=function() return 1 end
    local lookups=0
    env.rawget=function(t,k) if k=='ModOptionsMenu' then lookups=lookups+1 end;return rawget(t,k) end
    local depths={}
    local patch={apply=function() return true,'ready',false end,restore=function() return true end,
        MIN_WATER_DEPTH=0.20,SWIM_DEPTH=1.30,set_max_water_depth=function(d) depths[#depths+1]=d;return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()(function()
        return {module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES,Runtime)
    local w={env=env,state=env.ShallowWaterDive,depths=depths}
    function w.updates(n) for _=1,n do assert(env.update()==1) end end
    function w.lookups() local n=lookups;lookups=0;return n end
    return w
end
local function menu(accept,fields)
    local m={api=1,registrations=0,get=function() return 0.6 end,on_change=function() return true end}
    m.register_option=function()
        m.registrations=m.registrations+1
        if type(accept)=='function' then return accept() end
        return accept,not accept and 'menu full' or nil
    end
    for k,v in pairs(fields or {}) do m[k]=v end
    return m
end
do
    -- A menu that appears after the first update is registered with within 30 updates.
    local w=menu_watch_test()
    -- The first update looks and tries (the attempt looks again).
    w.updates(1);assert(w.state.depth_option=='not installed' and w.state.menu_attempts==1 and w.lookups()==2)
    w.updates(29);assert(w.lookups()==0)
    w.updates(1);assert(w.lookups()==1 and w.state.menu_attempts==1,'one look per 30 updates while unregistered')
    local late=menu(true);w.env.ModOptionsMenu=late
    w.updates(29);assert(late.registrations==0 and w.lookups()==0)
    w.updates(1);assert(w.state.depth_option=='registered' and w.state.menu_attempts==2 and late.registrations==1)
    assert(w.depths[1]==0.6 and w.lookups()==2)
    -- Registered: nothing per frame, and a replaced menu is not followed.
    w.env.ModOptionsMenu=menu(true)
    w.updates(300);assert(w.lookups()==0 and w.state.menu_attempts==2 and w.env.ModOptionsMenu.registrations==0)
    -- A refusal is tried again only after the menu's revision changes.
    w=menu_watch_test()
    local full=menu(false,{revision=1});w.env.ModOptionsMenu=full
    w.updates(1);assert(w.state.depth_option=='not registered: menu full' and full.registrations==1)
    w.updates(300);assert(full.registrations==1 and w.state.menu_attempts==1)
    full.revision=2;full.register_option=menu(true).register_option
    w.updates(30);assert(w.state.depth_option=='registered' and w.state.menu_attempts==2)
    -- Another API table (identity) is tried again, and a failing menu stays contained.
    w=menu_watch_test()
    w.env.ModOptionsMenu=menu(function() error('menu error',0) end)
    w.updates(1);assert(w.state.depth_option=='failed: menu error')
    local replacement=menu(true);w.env.ModOptionsMenu=replacement
    w.updates(30);assert(w.state.depth_option=='registered' and replacement.registrations==1 and w.state.menu_attempts==2)
    -- At most 8 attempts, even when the revision changes every update; then
    -- the menu is not looked at again.
    w=menu_watch_test()
    local churn=menu(false,{revision=0});w.env.ModOptionsMenu=churn
    for _=1,1000 do churn.revision=churn.revision+1;w.updates(1) end
    assert(churn.registrations==8 and w.state.menu_attempts==8 and w.state.depth_option=='not registered: menu full')
    w.lookups();w.updates(300);assert(w.lookups()==0 and churn.registrations==8)
end
print('PASS: Mod Options Menu registration retried when the menu\'s table or revision changes (looked at every 30 updates, at most 8 attempts); nothing per frame once registered')
-- Bingus Shared Loader v19 (capabilities.after_startup): the slider registers
-- once, from after_startup, after every mod has started and before the first
-- update; no frame looks at the menu. The fake loader's modes: 'queue' (the
-- callback runs when the test calls run(), as the loader does once every mod
-- has started), 'now' (startup has finished: it runs at once), 'refuse'
-- (false and a reason), 'raise', and 'lost' (accepted, run only if the test
-- calls run() later). Only the capability counts, never the version field.
local function v19_loader(mode,fields)
    local queue,logs={},{}
    local loader={api=1,version=17,calls=0,logs=logs}
    loader.capabilities=setmetatable({},{__index={api=1,logs=true,after_startup=true},
        __newindex=function() error('read-only',2) end,__metatable=false})
    function loader.after_startup(fn)
        loader.calls=loader.calls+1
        if mode=='refuse' then return false,'after_startup: 256 callbacks already registered' end
        if mode=='raise' then error('broken loader',0) end
        if mode=='now' then pcall(fn);return true end
        queue[#queue+1]=fn;return true
    end
    function loader.run() local list=queue;queue={};for _,fn in ipairs(list) do pcall(fn) end;return #list end
    function loader.open_log()
        local text={}
        logs[#logs+1]=text
        return {write=function(_,line) text[#text+1]=line end,close=function() end}
    end
    for k,v in pairs(fields or {}) do loader[k]=v end
    return loader
end
do
    -- Not at the install, not on an update: once, when the loader runs the callback.
    local loader,m=v19_loader('queue'),menu(true)
    local w=menu_watch_test(loader,m)
    assert(loader.calls==1 and w.state.menu_attempts==0 and m.registrations==0 and w.state.depth_option==nil)
    assert(loader.run()==1 and w.lookups()==1)
    assert(m.registrations==1 and w.state.menu_attempts==1 and w.state.depth_option=='registered')
    assert(w.state.menu_registration=='after_startup' and #w.depths==1 and w.depths[1]==0.6)
    local log=table.concat(loader.logs[#loader.logs])
    assert(log:find('\nmenu_attempts=1\ndepth_option=registered\nmenu_registration=after_startup\n',1,true),log)
    -- No frame looks at the menu, not even for a replaced menu or a new revision.
    w.updates(300);assert(w.lookups()==0)
    local replaced=menu(true,{revision=5});w.env.ModOptionsMenu=replaced;w.updates(300)
    assert(w.lookups()==0 and replaced.registrations==0 and m.registrations==1 and w.state.menu_attempts==1)
    assert(loader.run()==0 and m.registrations==1)
    -- A loader whose startup has finished runs the callback at once, during the
    -- install and after the startup report, which the registration report follows.
    loader,m=v19_loader('now'),menu(true)
    w=menu_watch_test(loader,m)
    assert(loader.calls==1 and m.registrations==1 and w.state.menu_attempts==1 and w.state.depth_option=='registered')
    assert(#loader.logs==2 and loader.logs[1][1]=='test\nwaiting_for_mission\n' and loader.logs[2][1]=='test\nwaiting_for_mission\n')
    w.lookups();w.updates(300);assert(w.lookups()==0 and m.registrations==1)
    -- One attempt per session: a missing, refusing or failing menu is not tried again.
    for _,case in ipairs({{nil,'not installed'},{menu(false,{revision=1}),'not registered: menu full'},
        {menu(function() error('menu error',0) end),'failed: menu error'}}) do
        loader=v19_loader('queue')
        w=menu_watch_test(loader,case[1])
        loader.run()
        assert(w.state.depth_option==case[2] and w.state.menu_attempts==1 and w.state.menu_registration=='after_startup')
        if case[1] then case[1].revision=(case[1].revision or 0)+1 end
        local later=menu(true);w.env.ModOptionsMenu=later
        w.lookups();w.updates(300)
        assert(w.lookups()==0 and w.state.menu_attempts==1 and later.registrations==0,case[2])
    end
    -- Only the capability counts: a loader numbered 6 with it registers there.
    loader=v19_loader('queue',{version=6})
    w=menu_watch_test(loader,menu(true));loader.run()
    assert(w.state.menu_registration=='after_startup' and w.state.depth_option=='registered')
end
do
    -- Otherwise the retry runs exactly as with loader v18: the same looks,
    -- attempts and registrations, update for update.
    local function retry_trace(loader)
        local w=menu_watch_test(loader)
        local trace,late={},menu(true)
        w.updates(1);trace[#trace+1]=w.state.depth_option..' '..w.state.menu_attempts..' '..w.lookups()
        w.updates(29);trace[#trace+1]=w.lookups()
        w.env.ModOptionsMenu=late
        w.updates(30);trace[#trace+1]=w.state.depth_option..' '..w.state.menu_attempts..' '..late.registrations..' '..w.lookups()
        w.updates(300);trace[#trace+1]=w.lookups()..' '..late.registrations..' '..tostring(w.state.menu_registration)
        return table.concat(trace,'|'),w,late
    end
    local expected=retry_trace({api=1,version=6,open_log=function() end})
    assert(expected=='not installed 1 2|0|registered 2 1 2|0 1 nil',expected)
    local plain={api=1,version=99,calls=0,open_log=function() end}
    plain.after_startup=function() plain.calls=plain.calls+1;return true end
    local loaders={refused=v19_loader('refuse'),raised=v19_loader('raise'),
        ['capability missing']=v19_loader('queue',{capabilities=setmetatable({},{__index={api=1}})}),
        ['capabilities not a table']=v19_loader('queue',{capabilities=true}),
        ['function missing']=v19_loader('queue',{after_startup=true}),
        ['no capabilities, version 99']=plain}
    for label,loader in pairs(loaders) do
        assert(retry_trace(loader)==expected,label)
    end
    assert(plain.calls==0 and loaders['capability missing'].calls==0 and loaders.refused.calls==1)
    -- Accepted but not run before the first update: the retry takes over, and a
    -- late run of the callback changes nothing.
    local lost=v19_loader('lost')
    local trace,w,late=retry_trace(lost)
    assert(trace==expected and lost.calls==1)
    assert(lost.run()==1 and w.state.menu_attempts==2 and late.registrations==1 and w.state.menu_registration==nil)
end
print('PASS: with the loader\'s after_startup capability the depth slider registers once, after every mod has started and before the first update, and no frame looks at the menu; without it, or when the loader refuses, raises or never runs the callback, the bounded retry runs exactly as with loader v18')
-- The after-update boundary is checked only while a lease or a retry is in
-- progress or a local avatar exists (the patch's idle gate then costs one read).
local function checks_per_update(set)
    local env=setmetatable({print=function()end},{__index=_G});env._G=env
    env.CowboyBingusModLoader={api=1,version=6,open_log=function() end};env.update=function() return 1 end
    local calls=0
    local patch={apply=function(a,g,e,state) calls=calls+1;set(state);return true,'ready',false end,
        restore=function() return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()(function()
        return {module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES,Runtime)
    env.update();return calls
end
assert(checks_per_update(function() end)==1)
assert(checks_per_update(function(state) state.gate_controller=0x40000000 end)==2)
assert(checks_per_update(function(state) state.retry_start=true end)==2)
assert(checks_per_update(function(state) state.pending={} end)==2)
print('PASS: minimum/newer loader and API gates, duplicate loads, callback tuples, shutdown, update exceptions and failure isolation')
print('PASS: after-update check only while a lease, retry or local avatar exists')
-- Routine checks keep the status in ShallowWaterDive without writing the log;
-- startup, the menu registration and shutdown write it, and diagnostics
-- (CowboyBingusDiagnostics = true) add writes at most every 2 s.
for _,diagnostics in ipairs({false,true}) do
    local now,opens,lines=0,0,{}
    local env=setmetatable({print=function()end},{__index=_G});env._G=env
    env.CowboyBingusDiagnostics=diagnostics
    env.CowboyBingusModLoader={api=1,version=99,open_log=function()
        opens=opens+1;lines={}
        return {write=function(_,text) lines[#lines+1]=text end,close=function() end}
    end}
    env.update=function() return 1,nil,3 end;env.shutdown=function() return 4,nil,6 end
    local api={time=function() return now end,module=function(n) return n and 1 or 2 end,
        module_hash=function(n) return n==1 and 'game' or 'exe' end}
    local reasons,i={'dive_ended','airborne_reference','landing','water_too_deep'},0
    local patch={apply=function(a,g,e,state) i=i+1;state.observed=i;return true,reasons[i%4+1],false end,
        restore=function() return true end,MIN_WATER_DEPTH=0.20,SWIM_DEPTH=1.30,set_max_water_depth=function() return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()(function() return api end,patch,
        {revision='fixture',game_sha256='game',exe_sha256='exe'},Text,LOCALES,Runtime)
    assert(opens==1 and lines[1]=='fixture\nwaiting_for_mission\n','startup report')
    local a,b,c=env.update();assert(a==1 and b==nil and c==3)
    assert(opens==2 and lines[#lines]=='menu_attempts=1\ndepth_option=not installed\n','menu registration report')
    for step=1,600 do now=step/60;a,b,c=env.update();assert(a==1 and b==nil and c==3) end
    assert(env.ShallowWaterDive.status==reasons[i%4+1] and env.ShallowWaterDive.observed==i)
    if diagnostics then assert(opens==7,'diagnostic writes every 2 s: '..opens)
    else assert(opens==2,'routine log writes need CowboyBingusDiagnostics') end
    a,b,c=env.shutdown();assert(a==4 and b==nil and c==6)
    assert(lines[1]=='fixture\nstopped\n' and lines[2]=='observed='..i..'\n','shutdown report')
    assert(lines[7]=='table_moves=0\n' and lines[8]=='protection_queries=0\n','page check counts in the report')
    assert(lines[9]=='pauses=0\nerrors=0\nerrors_below=0\n','guard counts in the report')
end
print('PASS: silent routine checks, startup/menu/shutdown log reports, throttled opt-in diagnostics')
print('PASS: Mod Options Menu depth slider registered once on the first update, applied values reach the patch, menu failures stay contained')
-- The update guard (bingus_runtime.lua): errors below this mod, its own
-- errors and refusals, with a fixture patch whose apply writes the water
-- record and takes a lease and whose restore puts it back.
local raised_at
local function vanilla_update_failure(err)
    raised_at=debug.getinfo(1,'Sl');error(err)
end
local function scenario()
    local f={memory='original',printed={},forwarded=0,shutdowns=0,applies=0}
    local env=setmetatable({os={getenv=function()end}},{__index=_G});env._G=env
    env.print=function(line) f.printed[#f.printed+1]=line end
    env.CowboyBingusModLoader={api=1,version=6,open_log=function() end}
    env.update=function(...)
        f.forwarded=f.forwarded+1
        if f.fail then vanilla_update_failure(f.fail) end
        return ...
    end
    env.shutdown=function(...) f.shutdowns=f.shutdowns+1;return ... end
    -- f.raise: apply raises; f.idle: no lease (no dive); f.refuse: a refusal.
    local patch={apply=function(a,g,e,state)
        f.applies=f.applies+1
        if f.raise then error(f.raise,0) end
        if f.idle then return true,'dive_ended',false end
        if f.refuse then return false,f.refuse,false end
        f.memory='patched';state.pending={};return true,'airborne_reference',true
    end,restore=function()
        if f.restore_error then error(f.restore_error,0) end
        f.memory='original';return true
    end}
    local api={module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()(function() return api end,patch,
        {revision='fixture',game_sha256='game',exe_sha256='exe'},Text,LOCALES,Runtime)
    -- Printed lines: '[ShallowWaterDiving] fixture: <status or guard line>'.
    function f.reports(status)
        local n=0
        for _,line in ipairs(f.printed) do if line=='[ShallowWaterDiving] fixture: '..status then n=n+1 end end
        return n
    end
    return env,f
end
-- An error raised by the game's update is not this mod's: it reaches the
-- caller unchanged, its traceback starts where it was raised and an error
-- object keeps its identity. The next update pauses the mod: it restores and
-- starts afresh, every update is still forwarded with all values, and it
-- checks again once the updates below have returned on 60 frames in a row.
do
    local env,f=scenario()
    local a,b,c=env.update(1,nil,3);assert(a==1 and b==nil and c==3 and f.memory=='patched' and f.applies==2)
    f.fail='vanilla update failure'
    local ok,trace=xpcall(env.update,debug.traceback,1,nil,3)
    assert(not ok and trace:find('vanilla update failure',1,true),trace)
    assert(trace:find('\n\t'..raised_at.short_src..':'..raised_at.currentline..": in function 'vanilla_update_failure'",1,true),
        'traceback must start where the update raised:\n'..trace)
    -- Nothing is handled while the error passes through.
    assert(f.memory=='patched' and env.ShallowWaterDive.status=='airborne_reference' and f.reports(PAUSED)==0)
    local object={};f.fail=object
    local raised,err=pcall(env.update,1,nil,3)
    assert(not raised and err==object,'an error object keeps its identity')
    -- That next update paused the mod: it restored before forwarding and did not check.
    assert(f.memory=='original' and f.applies==3 and f.forwarded==3 and not env.ShallowWaterDive.active)
    assert(env.ShallowWaterDive.status==PAUSED and f.reports(PAUSED)==1 and guard_status(env).state==PAUSED)
    assert(f.reports('ShallowWaterDiving paused: the previous update failed')==1)
    -- The first clean update counts the second error; 60 updates below
    -- return before the mod checks again.
    f.fail=false
    for i=1,30 do
        assert(select('#',env.update('one',nil,'three'))==3)
        a,b,c=env.update(i,nil,nil);assert(a==i and b==nil and c==nil)
    end
    assert(f.forwarded==63 and f.applies==3 and env.ShallowWaterDive.status==PAUSED and guard_status(env).lower_errors==2)
    a,b,c=env.update(1,nil,3);assert(a==1 and b==nil and c==3)
    assert(f.applies==5 and f.memory=='patched' and env.ShallowWaterDive.status=='airborne_reference')
    assert(guard_status(env).state=='running' and f.reports('ShallowWaterDiving resumed after 60 clean frames')==1)
    a,b,c=env.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    -- A resumed mod ends a clean session; the pause stays counted.
    assert(f.memory=='original' and env.ShallowWaterDive.status=='stopped' and guard_status(env).state=='stopped')
    assert(guard_status(env).pauses==1 and f.reports(PAUSED)==1)
end
-- Errors below that keep coming stop the mod: the 8th within a minute does;
-- the pause restored once and the stop restores again.
do
    local env,f=scenario();env.update()
    f.fail='vanilla update failure'
    for _=1,8 do assert(not pcall(env.update)) end
    assert(guard_status(env).lower_errors==7 and guard_status(env).state==PAUSED and f.applies==3)
    assert(not pcall(env.update))
    local reason='stopped after 8 failed updates below this mod'
    assert(guard_status(env).state=='stopped: '..reason and env.ShallowWaterDive.status==reason)
    assert(f.memory=='original' and guard_status(env).pauses==1 and f.reports(reason)==1)
    f.fail=false;env.update();env.update();assert(f.applies==3)
    env.shutdown();assert(guard_status(env).state=='stopped after: '..reason and env.ShallowWaterDive.status==reason)
end
-- Errors below separated by a clean minute never add up: ten pauses, still running.
do
    local env,f=scenario();f.idle=true
    for _=1,10 do
        f.fail='vanilla update failure';assert(not pcall(env.update));f.fail=false
        for _=1,3700 do env.update() end
    end
    assert(guard_status(env).state=='running' and guard_status(env).pauses==10 and guard_status(env).lower_errors<=1)
    assert(env.ShallowWaterDive.status=='dive_ended')
end
-- The mod's own errors are counted per burst: a clean minute (3600 updates)
-- clears the count, so seven errors twice never stop it; the 8th of a burst
-- does, with one log line per burst, and the first failure survives shutdown.
do
    local env,f=scenario();f.idle=true;f.raise='apply fixture error'
    for _=1,7 do env.update() end
    assert(guard_status(env).errors==7 and guard_status(env).state=='running' and f.applies==7)
    f.raise=false
    for _=1,3600 do env.update() end
    assert(guard_status(env).errors==0 and env.ShallowWaterDive.status=='dive_ended')
    f.raise='apply fixture error'
    for _=1,7 do env.update() end
    assert(guard_status(env).state=='running' and guard_status(env).errors==7)
    env.update()
    local reason='stopped after 8 errors: apply fixture error'
    assert(guard_status(env).state=='stopped: '..reason and env.ShallowWaterDive.status==reason)
    assert(f.reports('ShallowWaterDiving error: apply fixture error')==2 and f.reports(reason)==1)
    local applies=f.applies;env.update();assert(f.applies==applies)
    env.shutdown();assert(guard_status(env).state=='stopped after: '..reason and env.ShallowWaterDive.status==reason)
end
-- The first failure survives shutdown, including an update that raised just
-- before it; a refusal stops and restores at once and is kept; the stop work
-- runs once; plain 'stopped' only when nothing failed.
do
    local env,f=scenario();env.update();f.fail='vanilla update failure';assert(not pcall(env.update))
    assert(f.memory=='patched');env.shutdown()
    assert(f.memory=='original' and env.ShallowWaterDive.status=='stopped after: the previous update failed')
    assert(guard_status(env).state=='stopped after: the previous update failed')
    env,f=scenario();env.update();f.refuse='deliberate_failure';env.update()
    assert(f.memory=='original' and env.ShallowWaterDive.status=='deliberate_failure' and f.applies==3)
    env.shutdown()
    assert(env.ShallowWaterDive.status=='deliberate_failure' and guard_status(env).state=='stopped after: deliberate_failure')
    env,f=scenario();env.update();f.restore_error='restore fixture failure';f.refuse='deliberate_failure';env.update()
    assert(env.ShallowWaterDive.status=='deliberate_failure; restore_failed' and f.memory=='patched')
    local a,b,c=env.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    assert(guard_status(env).state=='stopped after: deliberate_failure')
    env,f=scenario();env.update();env.shutdown();assert(env.ShallowWaterDive.status=='stopped' and f.memory=='original')
end
-- Cleanup errors never reach the game: a raising restore at shutdown still
-- forwards it, and a pause whose restore fails stops the mod (which tries the
-- restore once more) while that update is still forwarded.
do
    local env,f=scenario();env.update();f.restore_error='restore fixture failure'
    local a,b,c=env.shutdown(4,nil,6);assert(a==4 and b==nil and c==6 and f.shutdowns==1)
    assert(env.ShallowWaterDive.status=='restore_failed')
    env,f=scenario();env.update();f.fail='vanilla update failure';assert(not pcall(env.update))
    f.fail=false;f.restore_error='restore fixture failure'
    a,b,c=env.update(1,nil,3);assert(a==1 and b==nil and c==3 and f.forwarded==3)
    assert(guard_status(env).state=='stopped: pause failed: restore_failed' and f.applies==3)
    assert(env.ShallowWaterDive.status=='pause failed: restore_failed; restore_failed')
    assert(f.reports('pause failed: restore_failed; restore_failed')==1)
end
print('PASS: update errors pass through unchanged; the next update pauses (restores and starts afresh) and resumes after 60 clean frames; 8 errors below or 8 own errors in a burst stop; clean minutes clear the counts; refusals stop at once; the first failure survives shutdown; cleanup errors stay contained')
