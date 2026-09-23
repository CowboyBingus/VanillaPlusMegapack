-- Reproduce the game's timer update and its separate row/tab action readers.
rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local module = assert(loadfile(assert(arg[2])))()
local directory = assert(arg[0]:match('^(.*)[/\\]'))
local fixture = assert(loadfile(directory .. '/runtime_fixture.lua'))()

for _, milliseconds in ipairs({4, 16, 33, 100, 600}) do
    for _, press_y in ipairs({515, 100}) do
        local f=fixture(module,{route='settings'})
        f.press(1005,press_y)
        f.move(900,595)
        for _=1,12 do f.tick(milliseconds) end
        assert(f.row_activations==0, 'Display drag must not activate rows after the native timer update')
        f.move(100,700)
        for _=1,12 do f.tick(milliseconds) end
        assert(f.tab_activations==0, 'Display drag must consume the selection read by tabs')
        local value=f.value
        assert(value>0.5 and not f.state.native_failed, 'input capture must preserve native scrolling')
        f.release()
        local consumes=f.consumes
        f.tick();f.tick()
        assert(f.consumes==consumes, 'released gestures must stop consuming input')
        f.press(100,700)
        assert(f.tab_activations==1, 'a fresh ordinary tab click must work immediately')
        f.release();f.press(900,595)
        assert(f.row_activations==1, 'a fresh option click must work immediately')
        assert(f.captures==0 and f.wheels==0 and f.logs==0 and f.state.errors==0,
            'settings capture must not add screenshots, injected input, logs or errors')
    end
end

for _, change in ipairs({'key','kind','content','span','items','hidden','refuse','ignore','error'}) do
    local f=fixture(module,{route='settings'})
    f.press(1005,515)
    if change=='key' or change=='kind' then f[change]='other'
    elseif change=='hidden' then f.visible=false
    elseif change=='error' then
        local state=module.native_state
        module.native_state=function() module.native_state=state;error('synthetic frame failure') end
    elseif change=='refuse' or change=='ignore' then f[change]=true
    else f[change]=f[change]+1 end
    f.move(900,595);f.tick(300)
    local writes=f.writes
    f.move(100,700);f.tick()
    assert(f.writes==writes and not f.state.drag_active, change..' must cancel scrolling')
    assert(f.row_activations==0 and f.tab_activations==0,
        change..' must not pass an already captured mouse hold to controls')
    f.release();f.visible=true;f.press(100,700)
    assert(f.tab_activations==1, change..' must allow the next ordinary click')
end

do
    local f=fixture(module,{route='settings'})
    f.press(1005,515);f.focused=false;f.move(900,595)
    f.focused=true;f.move(100,700)
    assert(f.row_activations==0 and f.tab_activations==0 and not f.state.drag_active,
        'focus loss cancels scrolling without handing the held click to a tab on return')
    f.release();f.press(100,700)
    assert(f.tab_activations==1, 'focus recovery allows a fresh click')
end

for _, route in ipairs({'grid','career','bindings'}) do
    local f=fixture(module,{route=route})
    f.press(1005,515);f.move(900,595);f.release()
    assert(f.consumes==0 and math.abs(f.value-0.6)<1e-6,
        'settings input capture must not change '..route..' gestures')
end
print('PASS: Display thumb/track drags across rows and tabs, native timer updates, release, cancellation and fresh clicks')
