return function(create_api,patch,build)
    if rawget(_G,'ReinforcementBeaconFixData') then return end
    local state={revision=build.revision,active=false,corrections=0}
    rawset(_G,'ReinforcementBeaconFixData',state)
    local function report(status,active)
        state.active=active
        if state.status==status then return end
        state.status=status
        print('[ReinforcementBeaconsFixed] '..build.revision..': '..status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ReinforcementBeaconsFixed.log')
            if not file then return end
            file:write(build.revision..'\n'..status..'\ncorrections='..state.corrections..'\n')
            if state.last then
                file:write(string.format('%s beacon=%d from=%.6f,%.6f to=%.6f,%.6f association=%s\n',
                    state.last.kind,state.last.beacon,state.last.from[1],state.last.from[2],
                    state.last.to[1],state.last.to[2],state.last.association or 'used'))
            end
            file:close()
        end)
    end
    local ok,api,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1,
            'Bingus Shared Loader API 1 or newer is required')
        local api=create_api()
        local game,exe=api.module('game.dll'),api.module(nil)
        assert(game and exe,'Required modules unavailable')
        assert(api.module_hash(game)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(exe)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
        return api,game,exe
    end)
    if not ok then report(tostring(api),false);return end
    report('waiting_for_reinforcement',false)
    local previous,stopped=update,false
    local function check()
        if stopped then return end
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then stopped=true;report(tostring(accepted),false);return end
        if not accepted then stopped=true end
        report(tostring(reason),active==true)
    end
    -- The second boundary only matters while a reinforcement is in progress:
    -- on the ship, while waiting for data or while alive, skip the repeat.
    local function after(...)
        local last=state.previous
        if last and last.owned and last.mode>=1 and last.mode<=7 and (last.state==1 or last.state==2) then
            check()
        end
        return ...
    end
    update=function(...)
        check()
        return after(previous(...))
    end
end
