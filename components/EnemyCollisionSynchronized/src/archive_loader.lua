return function(create_api,patch,build)
    if rawget(_G,'CorpseCollisionRepair') then return end
    local state={revision=build.revision,active=false,updates=0,polls=0,observed=0,
        realignments=0,claws_disabled=0,skipped=0,retries=0,max_gap=0}
    rawset(_G,'CorpseCollisionRepair',state)
    local api,last_log
    local function report(status,active,force)
        state.status=status;state.active=active
        local now=api and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[CorpseCollisionRepair] '..build.revision..': '..status) end
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('CorpseCollisionRepair.log');if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            for _,key in ipairs({'updates','polls','observed','realignments','claws_disabled','skipped','retries',
                'accepted_units','guard_passes_skipped','preflight_getter','getter_checks','getter_failures','last_getter_failure',
                'mission_flag','mode_field_40',
                'max_gap','last_unit','last_actor','read_bytes','read_calls','last_skip','profiler_failures',
                'fling_armed','fling_stops','fling_stops_verified','fling_handoffs','max_fling_distance',
                'last_fling_unit','last_fling_entity','last_fling_type','last_fling_reason',
                'fling_limb_stops','last_fling_actor','last_fling_limb_distance','last_fling_limb_degrees',
                'landed_disabled_stops','mixed_corpse_realignments',
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
        local g,e=api.module('game.dll'),api.module(nil)
        assert(g and e,'Required modules unavailable')
        assert(api.module_hash(g)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(e)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
        state.native=api.bind(g,e)
        return g,e
    end)
    if not ok then report(tostring(game),false,true);return end
    local profiler,original_read
    original_read=api.read
    local function disable_profiler()
        profiler=nil;api.profiler=nil;api.read=original_read
        state.profiler_failures=(state.profiler_failures or 0)+1
    end
    if patch.profiler then
        local created,value=pcall(patch.profiler.new,api,build.revision)
        if created then profiler=value;api.profiler=value else disable_profiler() end
    end
    local function telemetry(method,...)
        if not profiler then return end
        local called,value=pcall(profiler[method],...)
        if called then return value end
        disable_profiler()
    end
    local previous,previous_shutdown,stopped=update,shutdown,false
    local next_poll=0
    local function check()
        if stopped then return end
        local now=api.time();if now<next_poll then return end
        next_poll=now+patch.interval;state.polls=state.polls+1
        telemetry('begin',state)
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if profiler then
            state.read_calls=profiler.reads-profiler.read_start
            state.read_bytes=profiler.bytes-profiler.byte_start
            telemetry('phase','logging')
        end
        if not called then
            -- Loading/despawn can invalidate a sequential snapshot. Retry on
            -- the next poll; no cached addresses or pending writes survive it.
            state.retries=state.retries+1;state.last_skip=tostring(accepted)
            report('waiting_for_stable_data',false)
        elseif not accepted then
            stopped=true;report(tostring(reason),false,true)
        else report(reason,active==true) end
        telemetry('finish',state);telemetry('flush',state)
    end
    local function after(start,called,...)
        telemetry('update_finished',start,called)
        if not called then
            stopped=true;report('stopped_after_update_error',false,true);error((...),0)
        end
        check();return ...
    end
    update=function(...)
        state.updates=state.updates+1
        local start=telemetry('update_started')
        return after(start,pcall(previous,...))
    end
    shutdown=function(...)
        stopped=true;state.native=nil;report('stopped',false,true)
        telemetry('flush',state,true)
        if previous_shutdown then return previous_shutdown(...) end
    end
    report('waiting_for_mission',false,true)
end
