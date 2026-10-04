return function(create_api,patch,build,runtime)
    if rawget(_G,'ConsistentVaulting') then return end
    local state={revision=build.revision,active=false,prepared=0,metadata_fallbacks=0,observed_queries=0,
        updates=0,polls=0,fresh_queries=0,retry_calls=0,native_starts=0}
    rawset(_G,'ConsistentVaulting',state)
    local api,last_report
    local function report(status,active,force)
        local changed=state.status~=status
        state.active=active
        state.status=status
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_report and now-last_report<2 then return end
        if not force and not changed and not (api and api.time) then return end
        last_report=now
        print('[ConsistentVaulting] '..build.revision..': '..status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ConsistentVaulting.log')
            if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            file:write('observed_queries='..state.observed_queries..'\nprepared='..state.prepared
                ..'\nmetadata_fallbacks='..state.metadata_fallbacks..'\n')
            for _,key in ipairs({'updates','polls','stage_0','stage_1','stage_2','stage_3',
                'fresh_queries','retry_calls','native_starts','context_reprojections','query_rebuilds','reprojected_retries','reprojected_starts',
                'step_report_retries','step_report_starts',
                'slope_arms','slope_overrides','slope_climbs','slope_landings',
                'candidate_checks','raised_queries','raised_context_fallbacks','raised_approach_rebuilds','ledge_arms','ledge_climbs','ledge_attempt_expiries'}) do
                file:write(key..'='..tostring(state[key] or 0)..'\n')
            end
            file:write('last_phase='..tostring(state.phase or 'startup')..'\n')
            file:write('last_retry_reason='..tostring(state.last_retry_reason or 'none')..'\n')
            file:write('last_approach_reason='..tostring(state.last_approach_reason or 'none')..'\n')
            file:write('last_approach_code='..tostring(state.last_approach_code or 'none')..'\n')
            file:write('slope_status='..tostring(state.slope_status or 'startup')..'\n')
            file:write('slope_last_release='..tostring(state.slope_last_release or 'none')..'\n')
            file:write('candidate_reason='..tostring(state.candidate_reason or 'none')..'\n')
            file:write('candidate_height='..tostring(state.candidate_height or 'none')..'\n')
            file:write('candidate_normal_z='..tostring(state.candidate_normal_z or 'none')..'\n')
            file:write('last_candidate_snapshot_error='..tostring(state.candidate_error or 'none')..'\n')
            local outcomes={}
            for reason in pairs(state.candidate_results or {}) do outcomes[#outcomes+1]=reason end
            table.sort(outcomes)
            for _,reason in ipairs(outcomes) do
                file:write('candidate_result_'..reason..'='..state.candidate_results[reason]..'\n')
            end
            -- Retain the last fresh search across input release/waiting states.
            -- Its age and mover origin prevent attribution to a new position.
            local trace=state.raised_trace or state.candidate_trace
            if trace then
                file:write('probe_scope='..(state.raised_trace and 'last_raised_search' or 'last_search')..'\n')
                file:write('probe_approach_context='..tostring(trace.context or 'unknown')..'\n')
                file:write(string.format('probe_age_seconds=%.3f\nprobe_result=%s\nprobe_ground=%s\n',
                    math.max(0,now-trace.time),tostring(trace.result),tostring(trace.ground)))
                file:write(string.format('probe_native_mover=%.6f,%.6f,%.6f\n',unpack(trace.root)))
                file:write(string.format('probe_direction=%.6f,%.6f,%.6f\n',unpack(trace.direction)))
                for _,pass in ipairs({'ordinary','slope','raised'}) do
                    for _,row in ipairs(trace.passes[pass]) do
                        file:write(string.format('probe_%s_slot_%d=count:%d unit:%u height:%.6f max:%.6f normal_z:%.6f threshold:%.6f source_height:%.6f target_height:%.6f hit:%.6f,%.6f,%.6f motion:%s exit:%s veto:%s min:%s result:%s\n',
                            pass,row.slot,row.count,row.unit,row.height,row.max_height,row.normal_z,row.normal_threshold,
                            row.source_height,row.target_height,row.position[1],row.position[2],row.position[3],
                            tostring(row.motion_squared),tostring(row.exit),tostring(row.metadata_veto),tostring(row.min_height),tostring(row.result)))
                    end
                end
            end
            file:close()
        end)
    end
    local ok,adapter,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=5,
            'Bingus Shared Loader loader-v4 or newer / API 1 or newer is required')
        local adapter=create_api()
        local game_base,exe_base=adapter.module('game.dll'),adapter.module(nil)
        assert(game_base and exe_base,'Required modules unavailable')
        assert(adapter.module_hash(game_base)==build.game_sha256,'Unsupported game module')
        assert(adapter.module_hash(exe_base)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
        return adapter,game_base,exe_base
    end)
    if not ok then report(tostring(adapter),false,true);return end
    api=adapter
    -- The update chain is runtime.guard's (bingus_runtime.lua): the previous
    -- update runs outside pcall, so its errors reach the game unchanged; 8 of
    -- this mod's own errors in a burst stop it; after an error in an update
    -- below, the mod restores its changes, pauses and resumes once the updates
    -- below have returned on 60 frames in a row (8 such errors in a burst stop
    -- it); the first failure survives shutdown. stopped: the guard has stopped
    -- this mod and its stop work ran. skipped: the last check after the game's
    -- update did not run (idle).
    local guard,stopped,skipped=nil,false,false
    local function release()
        if patch.stop then return patch.stop(api,game,exe,state) end
        local restored=patch.restore(api,state.pending)
        if restored then state.pending=nil end
        return restored
    end
    -- Cleanup never raises into the game's update or shutdown; an error in it
    -- counts as a failed restore.
    local function cleanup() local called,restored=pcall(release);return called and restored end
    -- A fresh start, as after loading. A successful cleanup has already dropped
    -- the held query writes and the slope lease; this drops what else carries
    -- over between checks: the press window, the input edge (a fresh release is
    -- needed again), the retry interval, the avatar handed over within a check
    -- and the work in progress.
    local function reset()
        state.assist_intent=nil;state.slope_down=nil;state.last_retry_at=nil
        state.avatar=nil;state.busy=nil;state.active=false
        skipped=false
    end
    -- The patch raised: restore and start fresh, then raise the error again for
    -- the guard to count. A restore that fails stops the mod at once.
    local function failed(problem)
        if not cleanup() then return guard.stop(tostring(problem)) end
        reset()
        error(problem,0)
    end
    local function check(phase)
        if stopped then return end
        state.polls=state.polls+1;state.phase=phase
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then return failed(accepted) end
        -- A refusal stops the mod and is its first failure.
        if not accepted then return guard.stop(tostring(reason)) end
        report(tostring(reason),active==true,false)
    end
    -- One check per frame, before the game's update. Work that starts right
    -- after a skipped check gets that check now, still before the game's update,
    -- so it advances exactly as with two checks per frame (an assist armed with a
    -- climb already started caps its speed before the update, not one frame
    -- later).
    local function step()
        state.updates=state.updates+1
        check('before_update')
        if skipped and state.busy~=false then skipped=false;check('before_update') end
    end
    -- A second check after the game's update runs only while something is in
    -- progress (state.busy from the patch: held query writes, a slope assist or
    -- its press window, a vault check past its idle gates), because the update
    -- and other shared-loader/HUD wrappers may change that data. Idle, the next
    -- frame's check sees the same state before the next update. The native
    -- engine retains ownership of query scheduling.
    local function after()
        skipped=state.busy==false
        if not skipped then check('after_update') end
    end
    -- Once, when the guard stops this mod (a refusal, a failed restore after an
    -- error, 8 errors in a burst, a failed pause) or at shutdown: restore and
    -- report. At shutdown the first failure, if any, is kept in the status.
    local function stop(reason)
        stopped=true
        local restored=cleanup()
        if reason~='shutdown' then return report(restored and reason or 'local_restore_failed',false,true) end
        local failure=guard.status.first_failure
        report((restored and 'stopped' or 'local_restore_failed')..(failure and ' after: '..failure or ''),false,true)
    end
    -- An update below this mod raised: restore and start fresh. A restore that
    -- fails raises, and the guard stops the mod.
    local function pause()
        if not cleanup() then error('local_restore_failed',0) end
        reset()
    end
    local installed,why=pcall(function()
        guard=runtime.guard({name='ConsistentVaulting',env=_G,step=step,after=after,stop=stop,pause=pause,
            log=function(line) report(line,state.active,true) end}).install()
    end)
    if not installed then report(tostring(why),false,true);return end
    report('waiting_for_mission',false,true)
end
