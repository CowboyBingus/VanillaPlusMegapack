-- Synthetic native menu: never opens the game, captures pixels or writes files.
return function(module, options)
    options = options or {}
    local f = {now=1000, down=false, focused=true, visible=options.visible ~= false,
        x=1005, y=600, value=0.5, key='synthetic:grid', kind='grid',
        captures=0, wheels=0, writes=0, logs=0, resolves=0, binds=0, reads=0,
        updates=0, renders=0, closed=false, content=5000, span=4000, items=80,
        gate=0.504, gate_writes=0, consumes=0, row_activations=0, tab_activations=0}
    module.native_api = function()
        f.binds = f.binds + 1
        if options.unsupported then return nil, 'unsupported native scroll routine' end
        f.api={read=function(address, size)
            if address==0x0D000000+0x347cf18 and size==8 then return 'input' end
        end, pointer=function(bytes)
            if bytes=='input' then return 0x15000000 end
        end}
        return f.api
    end
    module.native_locate = function()
        f.resolves = f.resolves + 1
        if f.visible then return {key=f.key, route=options.route or 'grid', grid=100000,
            api=f.api, game=0x0D000000,
            memory={read_f32=function(address)
                if address==134124 then return f.gate end
            end, write_f32=function(address,value)
                if address~=134124 or options.gate_refused then return false end
                f.gate=value;f.gate_writes=f.gate_writes+1;return true
            end}} end
        return nil, 'no visible armory scrollbar'
    end
    module.native_calls = function()
        return {consume=function()
            if options.input_refused then return false end
            f.consumes=f.consumes+1
            f.select_pressed, f.select_value, f.select_held, f.select_released=false,0,0,false
        end}
    end
    module.native_state = function(bridge)
        f.reads = f.reads + 1
        if bridge.key ~= f.key or options.bad_model then return nil end
        return {value=f.value, content=f.content, span=f.span, viewport=1000,
            scroll=f.value*f.span, items=f.items, kind=f.kind,
            first=math.floor(f.value*f.span/200)*4, last=math.floor(f.value*f.span/200)*4+20,
            anchor=math.floor(f.value*f.span/200), rendered_thumb=1440-(100+f.value*800+200),
            geometry=not options.no_geometry and {left=1000,width=10,bottom=340,length=1000,thumb=200} or nil}
    end
    module.native_apply = function(_, _, value)
        f.writes = f.writes + 1
        if f.refuse then return nil, 'refused' end
        if not f.ignore then f.value=value end
        return value
    end
    local p = {
        now=function() return f.now end,
        pressed=function() return f.down end,
        foreground_self=function() return f.focused end,
        cursor=function() return f.x,f.y end,
        display_height=function() return 1440 end,
        viewport=function() return {x=0,y=0,height=1440} end,
        close=function() f.closed=true end,
        capture=function() f.captures=f.captures+1; error('runtime must not capture pixels') end,
        wheel=function() f.wheels=f.wheels+1; error('runtime must not inject wheel input') end,
    }
    local env = {update=function(dt)
            f.updates=f.updates+1
            if options.route=='settings' then
                -- Native settings update (0x180a800) advances the row-input
                -- timer before the handler tests it against 0.5. Category tabs
                -- read the select action independently of this timer.
                if f.gate<0.5 then f.gate=f.gate+dt end
                if f.focused and f.visible then
                    if f.x==900 and f.gate>=0.5 and f.select_held>0 then
                        f.row_activations=f.row_activations+1
                    elseif f.x==100 and (f.select_pressed or f.select_value>0) then
                        f.tab_activations=f.tab_activations+1
                    end
                end
            end
            return 1,nil,3
        end,
        render=function() f.renders=f.renders+1; return 4,nil,6 end,
        shutdown=function() return 7,nil,9 end,
        CowboyBingusModLoader={api=1,open_log=function()
            return {write=function() f.logs=f.logs+1 end,close=function() end}
        end}}
    f.render = env.render
    f.state = assert(module.install(function() return p end, env))
    f.state.base_settings = module.parse_settings(nil)
    f.state.settings = module.scale_settings(f.state.base_settings, 1)
    f.logs=0
    f.env, f.platform = env,p
    function f.tick(milliseconds)
        f.now=f.now+(milliseconds or 16)
        f.select_pressed=f.down and not f.previous_down
        f.select_released=not f.down and f.previous_down or false
        f.select_value,f.select_held=f.down and 1 or 0,f.down and 1 or 0
        f.previous_down=f.down
        local a,b,c=env.update((milliseconds or 16)/1000)
        assert(a==1 and b==nil and c==3, 'original update return tuple')
    end
    function f.press(x,y)
        f.down=false; f.tick()
        f.x,f.y=x or f.x,y or f.y
        f.down=true; f.tick()
    end
    function f.move(x,y) f.x,f.y=x,y; f.tick() end
    function f.release() f.down=false; f.tick() end
    return f
end
