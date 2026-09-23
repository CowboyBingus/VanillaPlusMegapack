-- Runtime regressions: native-only input, ownership, logging and callback chain.
rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local module = assert(loadfile(assert(arg[2])))()
local directory = assert(arg[0]:match('^(.*)[/\\]'))
local fixture = assert(loadfile(directory .. '/runtime_fixture.lua'))()
local passed = 0
local function check(ok, message) assert(ok,message); passed=passed+1 end
for _, options in ipairs({{visible=false},{unsupported=true},{bad_model=true},{no_geometry=true}}) do
    local f=fixture(module,options)
    for _=1,20 do f.press();f.release();f.tick(1100) end
    check(f.captures==0 and f.wheels==0 and f.writes==0, 'absent/unsupported owner must be inert')
    check(f.logs==0 and f.state.errors==0, 'ordinary clicks must not generate disk writes or errors')
    check(f.binds==1, 'unsupported native bindings must not be retried on clicks')
end
for _, condition in ipairs({'outside','unfocused','disabled','native_disabled'}) do
    local f=fixture(module)
    if condition=='outside' then f.x=100 end
    if condition=='unfocused' then f.focused=false end
    if condition=='disabled' then f.state.settings.enabled=false end
    if condition=='native_disabled' then f.state.settings.native=0 end
    for _=1,20 do f.press();f.release();f.tick(1100) end
    check(f.captures==0 and f.wheels==0 and f.writes==0, condition .. ' must not act')
    check(f.logs==0 and f.state.errors==0, condition .. ' must not log on clicks')
end
do
    local f=fixture(module)
    f.press(1005,515)
    check(f.writes==0, 'pressing thumb must not jump')
    f.move(-2000,595)
    check(math.abs(f.value-0.6)<1e-6, 'horizontal position must not affect captured drag')
    local writes=f.writes
    for _=1,40 do f.tick() end
    check(f.writes==writes and not f.state.native_failed, 'stationary pointer and readback must not move twice')
    f.move(4000,-200); check(f.value==0, 'top clamp')
    f.move(-2000,2500); check(f.value==1, 'bottom clamp')
    f.move(3000,515); check(math.abs(f.value-0.5)<1e-6, 'return to immutable grab point')
    f.release();writes=f.writes;f.move(1005,700)
    check(f.writes==writes and not f.state.drag_active, 'release ends ownership')
    check(f.captures==0 and f.wheels==0 and f.logs==0, 'native gestures need no screenshots, input injection or disk writes')
end
do
    local f=fixture(module,{route='settings'})
    f.press(1005,515)
    check(f.consumes==1 and f.gate_writes==0, 'settings press consumes native selection without changing the timer')
    f.move(900,595)
    check(f.x==900 and math.abs(f.value-0.6)<1e-6,
        'settings drag follows free mouse movement without activating row input')
    f.release()
    check(f.gate==0.504, 'settings drag leaves the native row timer untouched')
    f.press(1005,515);f.focused=false;f.tick()
    check(f.gate==0.504, 'settings focus loss leaves the native row timer untouched')
end
do
    local f=fixture(module,{route='settings',input_refused=true})
    f.press(1005,515);f.move(900,595)
    check(f.writes==0 and f.gate==0.504, 'settings route is inert if input consumption fails')
end
do
    local f=fixture(module)
    f.press(1005,100)
    check(f.value==0, 'track click reaches the top')
    f.move(-2000,280);check(math.abs(f.value-0.1)<1e-6, 'track press continues as a drag')
    f.focused=false;local writes=f.writes;f.move(0,600)
    f.focused=true;f.move(0,700)
    check(f.writes==writes and not f.state.drag_active, 'focus loss cancels until a fresh press')
end
for _, change in ipairs({'key','kind','content','span','items','hidden'}) do
    local f=fixture(module)
    f.press()
    if change=='key' or change=='kind' then f[change]='other'
    elseif change=='hidden' then f.visible=false
    else f[change]=f[change]+1 end
    f.move(0,700)
    check(f.writes==0 and not f.state.drag_active, change .. ' cancels stale ownership')
end
for _, mode in ipairs({'refuse','ignore'}) do
    local f=fixture(module)
    f[mode]=true
    f.press();f.move(0,700);f.tick(300)
    check(f.state.native_failed and f.captures==0 and f.wheels==0, mode .. ' retires without screenshot fallback')
    local writes=f.writes;f.release();f.press();f.move(0,750)
    check(f.writes==writes, 'retired owner cannot be written again')
end
do
    local f=fixture(module)
    f.press();f.move(0,600.5);f.tick(300)
    check(not f.state.native_failed and f.captures==0, 'sub-row movement verifies with native thumb geometry')
    check(f.env.render==f.render, 'render must not run the input processor again')
    local reads=f.reads;f.env.render();check(f.reads==reads, 'render performs no native reads')
    local a,b,c=f.env.shutdown()
    check(f.closed and a==7 and b==nil and c==9, 'shutdown cleans up and preserves return tuple')
end
do
    local f=fixture(module)
    f.state.settings.diagnostics=1
    f.press();f.move(0,650);f.release()
    for _=1,100 do f.tick() end
    check(f.logs<=1, 'opt-in diagnostics are rate limited')
end
print('install: '..passed..' native-only regression checks passed')
