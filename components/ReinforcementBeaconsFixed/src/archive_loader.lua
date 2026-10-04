-- The mod's lifecycle on bingus_runtime.lua's update guard (the family's
-- update-chain policy):
-- - the earlier update runs outside pcall, so its errors reach the game unchanged;
-- - one check before the earlier update, and a second after it only while a
--   reinforcement is in progress;
-- - the reader refuses an unsupported layout, and a failed write stops the
--   correction, by raising: either stops the mod at once, as before; errors in
--   the mod's own code stop it after 8 in a burst;
-- - after an error in an update below this mod, the mod puts back a pending
--   correction that still holds its bytes and forgets every association: once the
--   updates below have returned on 60 frames in a row it checks again. 8 such
--   errors in a burst stop it, with its correction put back. The game quitting
--   writes nothing.
return function(create_api,patch,build,runtime)
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
        assert(type(runtime)=='table' and type(runtime.guard)=='function','bingus_runtime.lua v1 is required')
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
    local guard
    local function check()
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then return guard.stop(tostring(accepted)) end
        if not accepted then return guard.stop(tostring(reason)) end
        report(tostring(reason),active==true)
    end
    -- The second boundary only matters while a reinforcement is in progress:
    -- on the ship, while waiting for data or while alive, skip the repeat.
    local function after()
        local last=state.previous
        if last and last.owned and last.mode>=1 and last.mode<=7 and (last.state==1 or last.state==2) then
            check()
        end
    end
    -- Puts back a pending correction that still holds this mod's bytes and
    -- starts afresh; a failed write raises.
    local function restore()
        local restored,outcome=patch.restore(api,game,state)
        if outcome~='nothing_to_restore' then report(state.status..'; '..outcome,false) end
        if not restored then error(outcome,0) end
    end
    -- At shutdown nothing is written: the game is freeing its memory.
    local function stop(reason)
        if reason~='shutdown' then restore() end
    end
    local prefix='ReinforcementBeaconsFixed '
    local function log(line)
        if line:sub(1,#prefix)==prefix then line=line:sub(#prefix+1) end
        report(line,false)
    end
    local installed,problem=pcall(function()
        guard=runtime.guard({name='ReinforcementBeaconsFixed',step=check,after=after,stop=stop,
            pause=restore,log=log,env=_G}).install()
    end)
    if not installed then report(tostring(problem),false) end
end
