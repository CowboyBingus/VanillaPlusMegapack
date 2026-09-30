local source=assert(arg[1])
-- The build passes the text module and the locales to the loader.
local Text=assert(loadfile(source..'/bingus_text.lua'))()
local LOCALES={en=assert(loadfile(source..'/../locales/en.lua'))(),bundled={}}
Text.registry().steam_language='en'
local function test(kind,loader,rejected)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    if loader==nil then loader={api=1,version=kind=='old_loader' and 5 or 6} end
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
    install(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES)
    if kind=='old_loader' or rejected then
        assert(env.update==original and calls==0 and not env.ShallowWaterDive.active)
        assert(env.ShallowWaterDive.status:find('Bingus Shared Loader',1,true))
        return
    end
    local update=env.update
    install(function()error('duplicate load')end,patch,{})
    assert(env.update==update)
    if kind=='update_error' then assert(not pcall(env.update));assert(restores==1)
    else
        local a,b,c=env.update();assert(a==1 and b==nil and c==3)
        if kind=='normal' then assert(calls==2 and select('#',env.update())==3)
        elseif kind=='initializing' then
            -- While waiting (no lease, retry or local avatar) only the
            -- before-update boundary is checked.
            assert(calls==1 and not env.ShallowWaterDive.active)
            env.update();env.update();env.update();assert(calls==4 and not env.ShallowWaterDive.active)
            env.update();assert(calls==6 and env.ShallowWaterDive.active)
        else assert(calls==1 and restores==1);env.update();assert(calls==1) end
    end
    local a,b,c=env.shutdown();assert(a==4 and b==nil and c==6)
end
for _,kind in ipairs({'normal','initializing','old_loader','update_error','patch_error','patch_failure'}) do test(kind)end
for _,loader in ipairs({{api=1,version=7},{api=2,version=6},{api=2,version=7},{api=99,version=100}}) do
    test('normal',loader)
end
for _,loader in ipairs({false,{}, {api=0,version=6},{api=2,version=5},
    {api='1',version=6},{api=1,version='6'},{api=1}}) do
    test('normal',loader,true)
end
-- Mod Options Menu: the depth slider registers on the first update only, its
-- applied value reaches the patch and later applied changes follow. Without
-- the menu, with another API, a refused registration or a failing menu,
-- nothing reaches the game's update and the reason is kept for the log.
local function menu_test(menu)
    local env=setmetatable({print=function()end,os={getenv=function()end}},{__index=_G});env._G=env
    env.CowboyBingusModLoader={api=1,version=6};env.ModOptionsMenu=menu
    local updates=0
    env.update=function() updates=updates+1;return 1 end
    local api={module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    local depths={}
    local patch={apply=function() return true,'ready',true end,restore=function() return true end,
        MIN_WATER_DEPTH=0.20,SWIM_DEPTH=1.30,set_max_water_depth=function(d) depths[#depths+1]=d;return true end}
    local install=setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()
    install(function()return api end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES)
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
-- The after-update boundary is checked only while a lease or a retry is in
-- progress or a local avatar exists (the patch's idle gate then costs one read).
local function checks_per_update(set)
    local env=setmetatable({print=function()end},{__index=_G});env._G=env
    env.CowboyBingusModLoader={api=1,version=6};env.update=function() return 1 end
    local calls=0
    local patch={apply=function(a,g,e,state) calls=calls+1;set(state);return true,'ready',false end,
        restore=function() return true end}
    setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()(function()
        return {module=function(n)return n and 1 or 2 end,module_hash=function(n)return n==1 and 'game' or 'exe' end}
    end,patch,{revision='test',game_sha256='game',exe_sha256='exe'},Text,LOCALES)
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
        {revision='fixture',game_sha256='game',exe_sha256='exe'},Text,LOCALES)
    assert(opens==1 and lines[1]=='fixture\nwaiting_for_mission\n','startup report')
    local a,b,c=env.update();assert(a==1 and b==nil and c==3)
    assert(opens==2 and lines[#lines]=='depth_option=not installed\n','menu registration report')
    for step=1,600 do now=step/60;a,b,c=env.update();assert(a==1 and b==nil and c==3) end
    assert(env.ShallowWaterDive.status==reasons[i%4+1] and env.ShallowWaterDive.observed==i)
    if diagnostics then assert(opens==7,'diagnostic writes every 2 s: '..opens)
    else assert(opens==2,'routine log writes need CowboyBingusDiagnostics') end
    a,b,c=env.shutdown();assert(a==4 and b==nil and c==6)
    assert(lines[1]=='fixture\nstopped\n' and lines[2]=='observed='..i..'\n','shutdown report')
    assert(lines[7]=='table_moves=0\n' and lines[8]=='protection_queries=0\n','page check counts in the report')
end
print('PASS: silent routine checks, startup/menu/shutdown log reports, throttled opt-in diagnostics')
print('PASS: Mod Options Menu depth slider registered once on the first update, applied values reach the patch, menu failures stay contained')
