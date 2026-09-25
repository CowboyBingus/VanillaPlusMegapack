return function(create_api,patch,build)
    if rawget(_G,'SentryAimRetention') then return end
    local state={revision=build.revision,active=false,updates=0,polls=0,
        observed=0,holding=0,holds=0,releases=0,late_aim=0,records={},
        fire_paused=0,fire_pauses=0,fire_resumes=0,fire_records={},reselections=0}
    rawset(_G,'SentryAimRetention',state)
    local api,game,exe,last_log
    local function report(status,active,force)
        state.status=status;state.active=active
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[SentryAimRetention] '..build.revision..': '..status) end
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('SentryAimRetention.log');if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            for _,key in ipairs({'updates','polls','observed','holding','holds','releases','late_aim',
                'fire_paused','fire_pauses','fire_resumes','reselections'}) do
                file:write(key..'='..tostring(state[key])..'\n')
            end
            for id,r in pairs(state.fire_records) do
                file:write(string.format('fire_sentry=%d paused=%s error_degrees=%.2f reason=%s terrain=%s synced=%s travel_degrees=%.2f target=%d runtime_target=%d\n',
                    id,tostring(r.lease~=nil),r.error or 0,r.reason or 'tracking_or_settling',tostring(r.terrain_blocked),
                    tostring(r.synced),r.travel or 0,r.snapshot.target,r.snapshot.runtime_target))
                if r.query then
                    local q=r.query
                    file:write(string.format('clearance=%s hit_unit=%s target_unit=%s hit_distance=%.3f target_distance=%.3f hit_actor=%s age=%.3f hit_filter=%s\n',
                        q.reason,tostring(q.hit_unit),tostring(q.target_unit),q.distance or 0,q.length or 0,
                        tostring(q.hit_actor),r.terrain_age or 0,q.filter and string.format('%08x',q.filter) or 'unknown'))
                end
            end
            for id,r in pairs(state.records) do
                local s=r.latest or r.snapshot
                file:write(string.format('sentry=%d type=%s node=%d target=%d hold=%s\n',
                    id,s.profile,s.node,s.target,tostring(r.lease~=nil)))
            end
            file:close()
        end)
    end
    local ok,why=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=7,
            'Bingus Shared Loader loader-v6 or newer / API 1 or newer is required')
        api=create_api();game=api.module('game.dll');exe=api.module(nil)
        assert(game and exe,'Required modules unavailable')
        assert(api.module_hash(game)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(exe)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
    end)
    if not ok then report(tostring(why),false,true);return end
    local previous,previous_shutdown,stopped=update,shutdown,false
    local function cleanup()
        local called,restored=pcall(patch.stop,api,game,exe,state)
        return called and restored
    end
    local function check()
        if stopped then return end
        state.polls=state.polls+1
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called or not accepted then
            stopped=true;local restored=cleanup()
            report(tostring(called and reason or accepted)..(restored and '' or '; restore_failed'),false,true)
            return
        end
        state.last_reason=reason
        report(reason,active==true)
    end
    local function after(called,...)
        if not called then
            stopped=true
            report(cleanup() and 'stopped_after_update_error' or 'restore_failed',false,true)
            error((...),0)
        end
        -- With no sentries deployed the repeat at the second boundary finds
        -- nothing; a sentry placed mid-frame is picked up on the next frame.
        if state.last_reason~='waiting_for_sentries' then check() end
        return ...
    end
    update=function(...)
        state.updates=state.updates+1;check();return after(pcall(previous,...))
    end
    shutdown=function(...)
        stopped=true;report(cleanup() and 'stopped' or 'restore_failed',false,true)
        if previous_shutdown then return previous_shutdown(...) end
    end
    report('waiting_for_sentries',false,true)
end
