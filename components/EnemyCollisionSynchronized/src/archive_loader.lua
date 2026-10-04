return function(create_api,patch,build,runtime,runtime_memory)
    if rawget(_G,'CorpseCollisionRepair') then return end
    local state={revision=build.revision,active=false,updates=0,polls=0,observed=0,
        realignments=0,claws_disabled=0,skipped=0,retries=0,max_gap=0}
    rawset(_G,'CorpseCollisionRepair',state)
    local api,last_log
    -- Diagnostics are off unless CowboyBingusDiagnostics = true before this mod
    -- initializes. Only then does the profiler run (timed reads, thread cycle
    -- queries, a performance log every 10 s) and is the status log rewritten
    -- during play, at most every 2 s. Startup, pauses, stops and shutdown always
    -- write it.
    local diagnostics=rawget(_G,'CowboyBingusDiagnostics')==true
    local function report(status,active,force)
        state.status=status;state.active=active
        if not force and not diagnostics then return end
        local now=api and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[CorpseCollisionRepair] '..build.revision..': '..status) end
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('CorpseCollisionRepair.log');if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            for _,key in ipairs({'updates','polls','observed','realignments','claws_disabled','skipped','retries','pauses',
                'accepted_units','guard_passes_skipped','preflight_getter','getter_checks','getter_failures','last_getter_failure',
                'mission_flag','mode_field_40',
                'max_gap','last_unit','last_actor','read_bytes','read_calls','last_skip','profiler_failures',
                'fling_armed','fling_stops','fling_stops_verified','fling_handoffs','max_fling_distance',
                'last_fling_unit','last_fling_entity','last_fling_type','last_fling_reason',
                'fling_limb_stops','last_fling_actor','last_fling_limb_distance','last_fling_limb_degrees',
                'landed_disabled_stops','mixed_corpse_realignments','reposes_deferred',
                'completion_requests','completion_corpse_observed','completion_pending',
                'last_completion_unit','last_completion_entity','last_completion_uptime',
                'last_fling_distance','last_fling_degrees','last_fling_uptime'}) do
                file:write(key..'='..tostring(state[key] or 0)..'\n')
            end
            file:close()
        end)
    end
    local ok,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=9,
            'Bingus Shared Loader loader-v8 or newer / API 1 or newer is required')
        api=create_api()
        -- The module hashes come from the runtime's session cache: each module
        -- file is read at most once per session, for every mod together.
        local verified,why=runtime_memory.new(runtime).verify_build(build)
        if not verified then error(why,0) end
        assert(type(update)=='function','Game update unavailable')
        local g,e=api.module('game.dll'),api.module(nil)
        state.native=api.bind(g,e)
        return g,e
    end)
    if not ok then report(tostring(game),false,true);return end
    local profiler,original_read,original_view,original_view_read
    original_read,original_view,original_view_read=api.read,api.view,api.view_read
    local function disable_profiler()
        profiler=nil;api.profiler=nil;api.read=original_read;api.view=original_view;api.view_read=original_view_read
        state.profiler_failures=(state.profiler_failures or 0)+1
    end
    if diagnostics and patch.profiler then
        local created,value=pcall(patch.profiler.new,api,build.revision)
        if created then profiler=value;api.profiler=value else disable_profiler() end
    end
    local function telemetry(method,...)
        if not profiler then return end
        local called,value=pcall(profiler[method],...)
        if called then return value end
        disable_profiler()
    end
    -- The update chain runs through runtime.guard (bingus_runtime.lua): the
    -- previous update runs outside pcall and its errors reach the game
    -- unchanged; after such an error below this mod it pauses (no poll, so no
    -- native command; patch.reset forgets every unit, motion history, stop,
    -- scan position and cooldown) and polls afresh once the updates below have
    -- returned on 60 frames in a row; 8 errors below in a burst stop it; the
    -- first failure survives shutdown (BingusRuntime.statuses). One exception
    -- (docs/TECHNICAL.md): a poll that raises is retried on the next poll, and
    -- 8 raised polls in a row stop the mod; a successful poll resets that
    -- count and a pause keeps it. These are mostly transient races with the
    -- game (units despawning in the middle of a read) whose real-play rate is
    -- unmeasured; counted in the guard's bursts, they could stop the mod in the
    -- middle of a mission. So the poll is caught and counted here, and only
    -- other errors in the mod's own frame reach the guard.
    local ERRORS=8
    local guard,next_poll,raised,first_raised,resumed,update_start=nil,0,0,nil,false,nil
    -- failure: the first failure in this mod's own words; status: its stop text.
    local failure,stop_status
    -- The mod refuses (a poll declined) or gives up (raised polls in a row).
    local function give_up(reason,status)
        failure,stop_status=failure or reason,status or reason
        guard.stop(reason)
    end
    local function poll_failed(why)
        state.retries=state.retries+1;state.last_skip=why
        raised=raised+1;if raised==1 then first_raised=why end
        if raised<ERRORS then report('waiting_for_stable_data',false)
        else give_up(first_raised,'stopped after: '..first_raised) end
    end
    local function check()
        local now=api.time();if now<next_poll then return end
        next_poll=now+patch.interval;state.polls=state.polls+1
        telemetry('begin',state)
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if profiler then
            state.read_calls=profiler.reads-profiler.read_start
            state.read_bytes=profiler.bytes-profiler.byte_start
            telemetry('phase','logging')
        end
        if not called then poll_failed(tostring(accepted))
        elseif not accepted then give_up(tostring(reason))
        else raised=0;report(reason,active==true) end
        telemetry('finish',state);telemetry('flush',state)
    end
    -- After the updates below returned: the first frame after a pause reports
    -- the resume, then the poll runs when due.
    local function after()
        if resumed then resumed=false;report('resumed_after_60_clean_frames',false,true) end
        state.updates=state.updates+1
        telemetry('update_finished',update_start,true);update_start=nil
        check()
    end
    -- An update below raised: report once, forget what the polls learned and
    -- poll again as soon as the mod resumes. A reset that raises stops the mod.
    local function pause()
        state.pauses=(state.pauses or 0)+1
        telemetry('update_finished',nil,false)
        report('paused_after_update_error',false,true)
        next_poll=0;patch.reset(state)
        resumed=true
    end
    -- The guard's stop reasons in this mod's status texts.
    local function stop_text(reason)
        if reason=='stopped after '..ERRORS..' failed updates below this mod' then return 'stopped_after_'..ERRORS..'_update_errors' end
        local why=reason:match('^pause failed: (.*)$')
        return why and 'pause_failed: '..why or reason
    end
    -- At shutdown, the final status; an update below that raised right before
    -- it counts as the failure. Protected: it never raises into the chain.
    local function shut_down()
        if not failure and guard.status.first_failure=='the previous update failed' then
            failure='stopped_after_update_error';telemetry('update_finished',nil,false)
        end
        report(failure and 'stopped after: '..failure or 'stopped',false,true)
        telemetry('flush',state,true)
    end
    local function stop(reason)
        state.native=nil
        if reason=='shutdown' then
            local done,why=pcall(shut_down);if not done then state.shutdown_error=tostring(why) end
            return
        end
        local status=stop_status or stop_text(reason)
        failure=failure or status
        report(status,false,true)
        telemetry('flush',state,true)
    end
    -- The guard's line for the first of a burst of the mod's own errors (the
    -- poll is caught above) goes to the status log once. Its pause, resume and
    -- stop lines are covered by the reports above.
    local NAME='EnemyCollisionSynchronized'
    local function log(line)
        if line:sub(1,#NAME+8)==NAME..' error: ' then report(line,state.active,true) end
    end
    guard=runtime.guard({name=NAME,step=profiler and function()
        update_start=telemetry('update_started')
    end or nil,after=after,stop=stop,pause=pause,log=log,env=_G}).install()
    report('waiting_for_mission',false,true)
end
