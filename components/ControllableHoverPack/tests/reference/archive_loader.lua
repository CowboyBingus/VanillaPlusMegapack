-- runtime: src/bingus_runtime.lua (v1). Its guard holds the update chain: the
-- updates below this mod run outside pcall, so their errors reach the game
-- unchanged; this mod's work runs after them under pcall. 8 of its own errors
-- stop it, counted per burst (a count starts again after 3600 clean frames).
-- An error below pauses it: the hover duration is restored, the flight
-- forgotten, and the work resumes once the updates below have returned on 60
-- frames in a row (8 such errors stop it). The first failure survives
-- shutdown, here and in BingusRuntime.statuses.ControllableHoverPack.
return function(create_api,patch,build,runtime)
    if rawget(_G,'HoverPackCancel') then return end
    local state={revision=build.revision,cancellations=0,updates=0,active=false}
    rawset(_G,'HoverPackCancel',state)
    local api,last_report
    local function report(status,force)
        state.status=status
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time() or 0
        if not force and last_report and now-last_report<2 then return end
        last_report=now
        print('[ControllableHoverPack] '..build.revision..': '..status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local f=logger and logger.open_log and logger.open_log('ControllableHoverPack.log');if not f then return end
            f:write(build.revision..'\n'..status..'\n')
            for _,key in ipairs({'updates','cancellations','restorations','snapshot_waits','settings_waits','restore_waits'}) do
                f:write(key..'='..tostring(state[key] or 0)..'\n')
            end
            for _,key in ipairs({'snapshot_status','mission_type','last_snapshot_error','last_settings_error','last_restore_error'}) do
                f:write(key..'='..tostring(state[key] or 'none')..'\n')
            end
            f:close()
        end)
    end
    local ok,adapter,game,exe=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=12,'Bingus Shared Loader v11 / API 1 is required')
        local a=create_api();local g,e=a.module('game.dll'),a.module(nil)
        assert(g and e,'Required modules unavailable')
        assert(a.module_hash(g)==build.game_sha256 and a.module_hash(e)==build.exe_sha256,'Unsupported game build')
        assert(type(update)=='function','Game update unavailable')
        return a,g,e
    end)
    if not ok then report(tostring(adapter),true);return end
    api=adapter
    -- restore_logged: the first restore that raised is logged, once per
    -- session. After a stop: retry_pending, a lease is left to restore;
    -- retry_frame, updates since the stop; retry_next, the next attempt's.
    local restore_logged,retry_pending,retry_frame,retry_next,shutting_down,guard=false,false,0,1,false,nil
    -- patch.cleanup restores the hover duration and forgets the flight: true
    -- and why it still waits (nil once restored), or false and why it raised.
    local function cleanup()
        local ok,result,reason=pcall(patch.cleanup,api,game,state)
        if ok then return true,reason end
        reason=tostring(result)
        if not restore_logged then restore_logged=true;report('restore_failed: '..reason,true)end
        return false,reason
    end
    -- After a stop the guard runs nothing of this mod. A lease the stop could
    -- not restore is tried again on the 1st, 2nd, 4th ... 512th update after
    -- it (10 attempts over about 8.5 s at 60 FPS), so a short read failure
    -- such as a mission transition can pass. An attempt that raises and one
    -- that keeps the lease count alike; after the last, one line names why.
    -- Updates are counted; the clock is not read.
    local RETRY_LAST=512
    local function retry_restore()
        retry_frame=retry_frame+1
        if retry_frame<retry_next then return end
        local _,reason=cleanup()
        if not state.lease then retry_pending=false
        elseif retry_next<RETRY_LAST then retry_next=retry_next*2
        else
            retry_pending=false
            report('restore_abandoned after 10 retries: '..tostring(reason or 'hover duration not restored'),true)
        end
    end
    -- The last restore attempt and report, with the first failure, at shutdown.
    local function finish()
        state.active=false;retry_pending=false
        local failure=guard.status.first_failure
        local ran=cleanup()
        report((ran and not state.lease and 'stopped' or 'restore_failed')..(failure and ' after: '..failure or ''),true)
    end
    -- Every frame the guard runs this mod: the work, after the game's update.
    -- An error here goes to the guard, which counts it.
    local function after()
        state.updates=state.updates+1;state.active=false
        local status=patch.apply(api,game,exe,state)
        state.active=status=='watching_hover' or status=='native_descent'
        report(tostring(status))
    end
    -- An update below raised: restore and start afresh while the guard pauses
    -- this mod. A restore that cannot finish now raises, and the guard stops
    -- the mod instead, as it did on every such error before.
    local function pause()
        state.active=false
        cleanup()
        if state.lease then error('hover duration not restored',0) end
    end
    -- The guard stopped this mod (it calls this once, also at shutdown).
    local function stop()
        if shutting_down then return finish() end
        state.active=false
        cleanup()
        retry_pending,retry_frame,retry_next=state.lease~=nil,0,1
    end
    local PREFIX='ControllableHoverPack '
    local function log(line)
        if line:sub(1,#PREFIX)==PREFIX then line=line:sub(#PREFIX+1) end
        report(line,true)
    end
    local installed,problem=pcall(function()
        guard=runtime.guard({name='ControllableHoverPack',after=after,pause=pause,stop=stop,log=log,env=_G}).install()
    end)
    if not installed then report(tostring(problem),true);return end
    -- After a stop the guard runs nothing of this mod, so the restore attempts
    -- above run here, before the guarded update. Every frame pays one boolean
    -- test and a tail call (unmeasured in game), so that a stop cannot leave a
    -- pack's hover duration cut; errors from below still reach the game
    -- unchanged.
    local guarded_update,guarded_shutdown=update,shutdown
    update=function(...)
        if retry_pending then retry_restore() end
        return guarded_update(...)
    end
    -- A running guard calls stop at shutdown (first failure already known);
    -- a stopped one does not, so the last attempt and report happen here.
    shutdown=function(...)
        shutting_down=true
        if not guard.running() then finish() end
        return guarded_shutdown(...)
    end
    report('waiting_for_mission',true)
end
