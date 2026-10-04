return function(create_api,native,policy,profile,signatures,build,image_native,images,image_signatures,dependencies)
    if rawget(_G,'ArmoryPreviewCache')then return end
    local state={revision=build.revision,status='starting',frames=0,
        policy_steps_skipped=0,policy_steps_full=0,policy_gate_misses=0}
    rawset(_G,'ArmoryPreviewCache',state)
    local previous,previous_shutdown=update,shutdown
    if type(previous)~='function'then state.status='disabled: update unavailable';return end
    local directory=os.getenv('LOCALAPPDATA')
    local path=directory and directory..'/ArmoryPreviewCache'
    local function read_file(name,limit)
        local f=path and io.open(path..name,'rb');if not f then return nil end
        local s=f:read((limit or 16384)+1);f:close();return s
    end
    -- Settings are read on the first update, like the learned profile. A read
    -- during resource loading was observed to miss an existing file in-game.
    local options
    local function load_settings()
        if options then return end
        local text=read_file('.ini',1024)
        options=profile.options(text)
        state.settings=text and 'file' or 'defaults'
    end
    local memory_guard=policy.new_memory_guard()
    local api,adapter,cache,image_cache,started,stopped,last_log,last_save,elapsed
    local baseline,baseline_world,last_profile
    -- The shared UI/thumbnail state view (image_native.state) and what the
    -- policy step last read: its snapshot, the state versions then and the
    -- pressure reason its last policy tick ran with.
    local watch,last_s,policy_version,lease_version,policy_pressure
    local guard
    local build_key=build.game_sha256..' '..build.exe_sha256
    elapsed=0
    local function log(force)
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        pcall(function() -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
            local logger=rawget(_G,'CowboyBingusModLoader')
            local f=logger and logger.open_log and logger.open_log('ArmoryPreviewCache.log');if not f then return end
            f:write(build.revision..'\nstatus='..state.status..'\n')
            if api and api.process_id then
                f:write('process_id='..api.process_id..'\nprocess_created_filetime_hex='..api.process_created_filetime_hex..'\n')
            end
            f:write('asset_residency_cache=1\nrendered_image_cache='..(image_cache and image_cache.enabled and '1' or '0')..'\nmax_packages=128\n')
            if image_cache then
                f:write('image_status='..image_cache.status..'\nimage_screen='..(image_cache.screen or 'none')..'\n')
                for _,key in ipairs({'bytes','hits','misses','last_hits','last_misses','early_hits','last_early_hits','retained','released','late_switches','pending_drops','ready_items','missing_ready_items','blank_ready_items','rendered_items','refreshed','changed_items','reappeared','pending_items','partial_retained','idle_retained','visible_retained','evicted','grid_hits','preselect_hits','briefing_hits','clear_count','widget_count','named_material_widgets',
                    'ticks','gated_ticks','full_changed','full_pending','full_pressure','full_retry','gate_misses',
                    'gate_misses_screen','gate_misses_items','gate_misses_widgets','gate_misses_presentation',
                    'gate_misses_registry','gate_misses_cards'})do
                    f:write('image_'..key..'='..tostring(image_cache[key] or 0)..'\n')
                end
                local a=image_cache.adapter or {}
                for _,key in ipairs({'prune_checks','prune_changes','prune_reconciles','prune_misses'})do
                    f:write('image_'..key..'='..tostring(a[key] or 0)..'\n')
                end
                f:write('image_atlases='..#image_cache.textures..'\n')
                f:write('image_last_clear_reason='..(image_cache.last_clear_reason or '')..'\n')
            end
            f:write('disk_enabled=false\ndisk_status=removed_after_v7_crash\n')
            f:write('settings='..(state.settings or 'pending')..'\n')
            f:write('prewarm='..(options and tostring(options.prewarm) or 'pending')..'\n')
            f:write('verify_gate='..(options and tostring(options.verify_gate) or 'pending')..'\n')
            if watch then f:write('state_refreshes='..watch.refreshes..'\n')end
            for _,key in ipairs({'frames','disabled_reason','disabled_frame','last_top','last_items','last_active','last_blocked','free_mib','commit_headroom_mib','private_growth_mib','pressure_reason','profile_error','disk_error','last_error',
                'policy_steps_skipped','policy_steps_full','policy_gate_misses','last_guard'})do
                local value=state[key];if value==nil then value=''end
                f:write(key..'='..tostring(value)..'\n')
            end
            f:write('memory_guard_trips='..memory_guard.trips..'\n')
            for _,key in ipairs({'last_reason','trigger_free_mib','trigger_commit_mib'})do
                f:write('memory_guard_'..key..'='..tostring(memory_guard[key] or '')..'\n')
            end
            if cache then
                local count=0;for _ in pairs(cache.leases)do count=count+1 end
                f:write('resident_packages='..count..'\nlearned_items='..#cache.learn_order..'\n')
                for _,key in ipairs({'acquires','releases','hits','unresolved','retired','prewarms','dependency_acquires','startup_acquires','foreground_pending'})do f:write(key..'='..tostring(cache[key] or 0)..'\n')end
            end
            f:close()
        end)
    end
    local function save(force)
        if not cache or not path then return end
        local now=api.time();if not force and last_save and now-last_save<5 then return end
        last_save=now
        -- Only remember() changes the learned list: without it the encoding
        -- equals the saved text, so the throttled save skips encoding it.
        if not force and cache.profile_changed==false then return end
        local text=profile.encode(cache:profile(),build_key)
        if text==last_profile then cache.profile_changed=false;return end
        local ok,why=pcall(function()
            local f=assert(io.open(path..'.profile.tmp','wb'));assert(f:write(text));f:close()
            -- Windows rename does not replace an existing destination. Keep a
            -- recoverable backup during replacement; decode rejects truncation.
            os.remove(path..'.profile.bak')
            os.rename(path..'.profile',path..'.profile.bak')
            assert(os.rename(path..'.profile.tmp',path..'.profile'))
            os.remove(path..'.profile.bak')
        end)
        if ok then last_profile=text;cache.profile_changed=false else state.profile_error=tostring(why)end
    end
    local function cleanup()
        if image_cache then
            local ok,why=pcall(image_cache.clear,image_cache)
            if not ok then state.last_error='image cleanup: '..tostring(why)end
        end
        if cache then
            pcall(save,true)
            local ok,why=pcall(cache.clear,cache)
            if not ok then state.last_error='cleanup: '..tostring(why)end
        end
    end
    local function initialize()
        if started then return end
        started=true
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(loader and loader.api==1,'Bingus Shared Loader API 1 required')
        api=create_api();api.assert_thread()
        local game,exe=assert(api.module('game.dll')),assert(api.module(nil))
        -- The shared runtime's memory api hashes each module once per session
        -- for every mod (build.memory, set by scripts/module.py).
        if build.memory then assert(build.memory.verify_build(build),'Unsupported game build')
        else assert(api.module_hash(game)==build.game_sha256 and api.module_hash(exe)==build.exe_sha256,'Unsupported game build')end
        adapter=native.new(api,game,exe,signatures,dependencies)
        cache=policy.new(adapter,options)
        watch=image_native and image_native.state and image_native.state(api,game)
        if images and options.images then
            local image_adapter=image_native.new(api,game,exe,image_signatures,nil,watch)
            image_cache=images.new(image_adapter,options)
        end
        local learned,valid=profile.decode(read_file('.profile',65536),build_key)
        if not valid then learned=profile.decode(read_file('.profile.bak',65536),build_key)end
        for _,item in ipairs(learned)do cache:remember(item)end
    end
    -- The fields the policy tick reads from a native snapshot, for verify_gate.
    local function policy_digest(s)
        local out={tostring(s.owner),tostring(s.world),tostring(s.menu),tostring(s.prefetch),
            tostring(s.blocked),tostring(s.top),tostring(s.active),table.concat(s.states or {},',')}
        for _,item in ipairs(s.items)do
            out[#out+1]=item.kind..':'..item.id..':'..tostring(item.finished)..':'..table.concat(item.attachments or {},',')
        end
        return table.concat(out,'|')
    end
    -- Whether this step can reuse the last native snapshot: everything that
    -- snapshot read is in the state view and unchanged since. The view reads
    -- the manager, controller rows and preview queue only on a thumbnail
    -- screen with a UI world; with an empty state stack or no world the
    -- native snapshot still reads the manager, so those steps read afresh.
    -- The weapon/kit catalogues and attachment tables it verifies are static
    -- game data; every fresh step verifies them as before.
    local function reusable(refreshes)
        if not watch or not last_s then return false end
        if watch.refreshes==refreshes then watch:refresh()end
        watch:refresh_lease()
        if not (watch.g_ok and watch.stack_ok and watch.ui_ok) or watch.depth==0
            or (watch.kind and not watch.world)then return false end
        return watch.policy_version==policy_version and watch.lease_version==lease_version
    end
    -- Memory telemetry (GlobalMemoryStatusEx and K32GetProcessMemoryInfo,
    -- unmeasured in game) feeds the memory guard. Its pressure reason changes
    -- what a step does only in a menu, in the startup prewarm window, while
    -- leases or rendered images are held, or while the guard is tripped or
    -- recovering: then memory is polled every step, as before. Otherwise (in a
    -- mission, on the ship outside a menu) a poll would only refresh the log's
    -- figures, so it runs every MEMORY_IDLE_POLL seconds. Entering a menu polls
    -- on that step: the snapshot is read first.
    local MEMORY_IDLE_POLL=2
    local memory_wait=0
    local function memory_matters(s)
        return s.menu or s.prefetch or memory_guard.active or next(cache.leases)~=nil
            or (image_cache~=nil and #image_cache.textures>0)
    end
    local function poll_memory(s,seconds)
        memory_wait=memory_wait-seconds
        if memory_wait>0 and not memory_matters(s)then return end
        memory_wait=MEMORY_IDLE_POLL
        local free,private,commit=api.memory()
        if not s.menu or baseline_world~=s.world then baseline=private;baseline_world=s.world end
        baseline=baseline or private
        local growth=math.max(0,private-baseline)
        state.free_mib=math.floor(free/1048576);state.private_growth_mib=math.floor(growth/1048576)
        state.commit_headroom_mib=math.floor(commit/1048576)
        state.pressure_reason=memory_guard:tick(api.time,free,commit)
    end
    -- step checks the update thread before the pre-update image refresh; the
    -- frame after the update checks it only when step did not (same callback,
    -- same thread): one GetCurrentThreadId per frame.
    local thread_checked=false
    local function frame(dt) -- lint-ok: R10 ported from v23 unchanged; split into named steps is a follow-up (differential harness ready)
        state.frames=state.frames+1
        if not stopped then load_settings()end
        if stopped or not options.enabled then state.status=stopped and state.status or 'disabled_by_config';log(false);return end
        if not started then
            local ok,why=pcall(initialize)
            if not ok then guard.stop('disabled: '..tostring(why));return end
        end
        if not thread_checked then api.assert_thread()end
        local refreshes=watch and watch.refreshes
        -- Presentation runs every callback, independent of the slower asset
        -- residency budget. A 50 ms image poll would itself add visible delay.
        if image_cache then image_cache:tick(state.pressure_reason~=nil)end
        elapsed=elapsed+(type(dt)=='number' and math.max(0,math.min(dt,.25)) or 0)
        if elapsed<.05 then return end
        local seconds=elapsed
        elapsed=0
        -- Memory telemetry and the guard run as poll_memory says. The native snapshot
        -- and the policy tick run unless the snapshot is reusable, the last
        -- policy tick was settled and the pressure reason is unchanged: that
        -- tick would only add the same hit counts, which replay() adds.
        local s,reuse=last_s,reusable(refreshes)
        if reuse and options.verify_gate then
            local ok,now=pcall(adapter.snapshot,adapter)
            if not ok or policy_digest(now)~=policy_digest(last_s)then
                state.policy_gate_misses=state.policy_gate_misses+1;reuse=false
            end
        end
        if not reuse then
            local ok
            ok,s=pcall(adapter.snapshot,adapter)
            if not ok then
                -- Loading screens can temporarily remove managers. Retain no new
                -- leases; cleanup only through revalidated ownership.
                last_s=nil
                cleanup();state.status='waiting_for_ui';state.last_error=tostring(s);log(false);return
            end
            last_s=s
            if watch then policy_version,lease_version=watch.policy_version,watch.lease_version end
        end
        poll_memory(s,seconds)
        state.last_top=s.top;state.last_items=#s.items;state.last_active=s.active
        state.last_blocked=s.blocked
        if reuse and cache.settled and state.pressure_reason==policy_pressure then
            cache:replay();state.policy_steps_skipped=state.policy_steps_skipped+1
        else
            cache:tick(s,api.time(),state.pressure_reason~=nil)
            policy_pressure=state.pressure_reason;state.policy_steps_full=state.policy_steps_full+1
        end
        state.status=cache.status
        -- Persist learned entries after menu interaction, or during shutdown.
        if not s.menu and not s.active then save(false) end
        log(false)
    end
    -- The update chain is the shared runtime's guard (BingusSharedRuntime):
    -- the previous update runs outside pcall; an update below that raises
    -- pauses the mod (cleanup hands every widget back to the native pipeline
    -- and releases the leases) until 60 clean frames, then it resumes; 8 own
    -- errors or 8 failures below in a burst stop it; the first failure
    -- survives shutdown.
    local last_dt
    local function step(dt)
        last_dt=dt
        thread_checked=image_cache~=nil and not stopped
        if thread_checked then api.assert_thread();image_cache:before()end
    end
    local function after()frame(last_dt)end
    local function pause(reason)
        cleanup();last_s=nil;state.status='paused: '..reason;log(true)
    end
    local function stop(reason)
        stopped=true;cleanup()
        if reason=='shutdown' then
            local failure=guard.status.first_failure
            state.status=failure and 'stopped after: '..failure or 'stopped'
        else
            state.status=reason;state.disabled_reason=reason;state.disabled_frame=state.frames
        end
        log(true)
    end
    guard=build.runtime.guard({name='ArmoryPreviewCache',step=step,after=after,pause=pause,stop=stop,
        log=function(line)state.last_guard=line end,env=_G}).install()
    -- A guard stopped earlier runs no stop work at shutdown: report it here.
    local guarded_shutdown=shutdown
    shutdown=function(...)
        if not guard.running()then
            local failure=guard.status.first_failure
            state.status=failure and 'stopped after: '..failure or 'stopped';log(true)
        end
        return guarded_shutdown(...)
    end
    log(true)
end
