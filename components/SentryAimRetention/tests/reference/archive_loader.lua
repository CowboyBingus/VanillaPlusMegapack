return function(create_api,patch,build,runtime)
    if rawget(_G,'SentryAimRetention') then return end
    local state={revision=build.revision,active=false,updates=0,polls=0,
        observed=0,holding=0,holds=0,releases=0,late_aim=0,records={},
        fire_paused=0,fire_pauses=0,fire_resumes=0,fire_records={},reselections=0,selections=0,engaged=false}
    rawset(_G,'SentryAimRetention',state)
    local api,game,exe,last_log,guard
    -- The last clearance query of a fire record.
    local function log_query(file,r)
        local q=r.query
        file:write(string.format('clearance=%s hit_unit=%s target_unit=%s hit_distance=%.3f target_distance=%.3f hit_actor=%s age=%.3f hit_filter=%s\n',
            q.reason,tostring(q.hit_unit),tostring(q.target_unit),q.distance or 0,q.length or 0,
            tostring(q.hit_actor),r.terrain_age or 0,q.filter and string.format('%08x',q.filter) or 'unknown'))
    end
    local function log_fire_records(file)
        for id,r in pairs(state.fire_records) do
            file:write(string.format('fire_sentry=%d paused=%s error_degrees=%.2f reason=%s terrain=%s synced=%s travel_degrees=%.2f target=%d runtime_target=%d\n',
                id,tostring(r.lease~=nil),r.error or 0,r.reason or 'tracking_or_settling',tostring(r.terrain_blocked),
                tostring(r.synced),r.travel or 0,r.snapshot.target,r.snapshot.runtime_target))
            if r.query then log_query(file,r) end
        end
    end
    local function log_aim_records(file)
        for id,r in pairs(state.records) do
            local s=r.latest or r.snapshot
            file:write(string.format('sentry=%d type=%s node=%d target=%d hold=%s\n',
                id,s.profile,s.node,s.target,tostring(r.lease~=nil)))
        end
    end
    -- The diagnostics log: the counters, every fire record and every aim record.
    local function write_log(status)
        local logger=rawget(_G,'CowboyBingusModLoader')
        local file=logger and logger.open_log and logger.open_log('SentryAimRetention.log');if not file then return end
        file:write(build.revision..'\n'..status..'\n')
        for _,key in ipairs({'updates','polls','observed','holding','holds','releases','late_aim',
            'fire_paused','fire_pauses','fire_resumes','reselections'}) do
            file:write(key..'='..tostring(state[key])..'\n')
        end
        log_fire_records(file)
        log_aim_records(file)
        file:close()
    end
    -- force: write the log now, without the diagnostics opt-in or the 2 s
    -- spacing, and print the status unless quiet (the guard has already printed
    -- its own line for a stop or a pause).
    local function report(status,active,force,quiet)
        state.status=status;state.active=active
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force and not quiet then print('[SentryAimRetention] '..build.revision..': '..status) end
        pcall(write_log,status)
    end
    -- report never compiled while it built the log closure (its returns closed
    -- upvalues, which the game's LuaJIT does not compile); it stays interpreted
    -- so the shared code cache is unchanged. The log helpers compile as before.
    if jit and jit.off then jit.off(report,true) end
    -- Restores every hold, fire pause and search request this mod owns: aim,
    -- retention bit, turret speeds, fire mode and selection deadline. A record
    -- that could not be restored stays for the next attempt.
    local function restore()
        local called,restored=pcall(patch.stop,api,game,exe,state)
        return called and restored
    end
    -- After a full restore nothing is in progress, so the next check starts as
    -- on a fresh load. The session counters stay, and so do the bound natives:
    -- their signatures are verified once per session.
    local function fresh_start()
        state.observed,state.holding,state.fire_paused,state.selections=0,0,0,0
        -- Nothing in progress: the check after the game update waits for the
        -- next frame's first check, and the next check locates every sentry again.
        state.last_reason='waiting_for_sentries';state.engaged=false;state.layout=nil
    end
    -- The mod's own check raised or refused. Everything it holds is restored
    -- and the next frame starts afresh; the error goes to the guard, which logs
    -- one line per burst and stops the mod after 8 errors in a burst. Without a
    -- full restore the mod stops at once.
    local function failed(problem)
        if not restore() then return guard.stop(problem) end
        fresh_start();report(problem,false)
        error(problem,0)
    end
    local function check()
        state.polls=state.polls+1
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called or not accepted then return failed(tostring(called and reason or accepted)) end
        state.last_reason=reason
        report(reason,active==true)
    end
    local function step()
        state.updates=state.updates+1;check()
    end
    local function after()
        -- The second check, after the game update, catches a target lost inside
        -- that update before the next frame. It runs only while a sentry is
        -- engaged (tracks a target, holds aim, pauses fire or waits on a search
        -- request); otherwise nothing it could see needs an answer this frame,
        -- and the next frame's first check sees the same state.
        if state.engaged then check() end
    end
    -- An update below this mod raised. The guard skips this mod until the
    -- updates below have returned on 60 frames in a row. A failed restore
    -- raises, and the guard stops the mod.
    local function pause()
        if not restore() then error('the sentry controls could not be restored',0) end
        fresh_start();report('paused_after_update_error',false,true,true)
    end
    -- Runs once: when the guard stops the mod (reason), or at shutdown, where
    -- the status keeps the first failure.
    local function stop(reason)
        local restored=restore()
        if reason~='shutdown' then return report(reason..(restored and '' or '; restore_failed'),false,true,true) end
        local status=restored and 'stopped' or 'restore_failed'
        local failure=guard.status.first_failure
        report(failure and status..' after: '..failure or status,false,true)
    end
    -- The guard's few lines: the first error of a burst, pause, resume and stop.
    local function log(line)
        print('[SentryAimRetention] '..build.revision..': '..(line:gsub('^SentryAimRetention ','')))
    end
    local ok,why=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=7,
            'Bingus Shared Loader loader-v6 or newer / API 1 or newer is required')
        -- The runtime's build check hashes each module file at most once per
        -- session for every mod on the runtime: 'game modules unavailable' or
        -- 'unsupported game build'.
        api=create_api()
        assert(api.verify_build(build))
        game,exe=api.module('game.dll'),api.module(nil)
        assert(type(update)=='function','Game update unavailable')
        -- The previous update runs outside pcall, so its errors reach the game
        -- unchanged; the first failure survives shutdown.
        guard=runtime.guard({name='SentryAimRetention',env=_G,step=step,after=after,pause=pause,stop=stop,log=log})
        guard.install()
    end)
    if not ok then report(tostring(why),false,true);return end
    report('waiting_for_sentries',false,true)
end
