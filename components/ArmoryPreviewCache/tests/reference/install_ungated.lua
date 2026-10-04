return function(create_api,native,policy,profile,signatures,build,image_native,images,image_signatures,dependencies)
    if rawget(_G,'ArmoryPreviewCache')then return end
    local state={revision=build.revision,status='starting',frames=0}
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
    local build_key=build.game_sha256..' '..build.exe_sha256
    elapsed=0
    local function log(force)
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local f=logger and logger.open_log and logger.open_log('ArmoryPreviewCache.log');if not f then return end
            f:write(build.revision..'\nstatus='..state.status..'\n')
            if api and api.process_id then
                f:write('process_id='..api.process_id..'\nprocess_created_filetime_hex='..api.process_created_filetime_hex..'\n')
            end
            f:write('asset_residency_cache=1\nrendered_image_cache='..(image_cache and image_cache.enabled and '1' or '0')..'\nmax_packages=128\n')
            if image_cache then
                f:write('image_status='..image_cache.status..'\nimage_screen='..(image_cache.screen or 'none')..'\n')
                for _,key in ipairs({'bytes','hits','misses','last_hits','last_misses','early_hits','last_early_hits','retained','released','late_switches','pending_drops','ready_items','missing_ready_items','blank_ready_items','rendered_items','refreshed','changed_items','reappeared','pending_items','partial_retained','idle_retained','visible_retained','evicted','grid_hits','preselect_hits','briefing_hits','clear_count','widget_count','named_material_widgets'})do
                    f:write('image_'..key..'='..tostring(image_cache[key] or 0)..'\n')
                end
                f:write('image_atlases='..#image_cache.textures..'\n')
                f:write('image_last_clear_reason='..(image_cache.last_clear_reason or '')..'\n')
            end
            f:write('disk_enabled=false\ndisk_status=removed_after_v7_crash\n')
            f:write('settings='..(state.settings or 'pending')..'\n')
            f:write('prewarm='..(options and tostring(options.prewarm) or 'pending')..'\n')
            for _,key in ipairs({'frames','disabled_reason','disabled_frame','last_top','last_items','last_active','last_blocked','free_mib','commit_headroom_mib','private_growth_mib','pressure_reason','profile_error','disk_error','last_error'})do
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
        local text=profile.encode(cache:profile(),build_key)
        if text==last_profile then return end
        local ok,why=pcall(function()
            local f=assert(io.open(path..'.profile.tmp','wb'));assert(f:write(text));f:close()
            -- Windows rename does not replace an existing destination. Keep a
            -- recoverable backup during replacement; decode rejects truncation.
            os.remove(path..'.profile.bak')
            os.rename(path..'.profile',path..'.profile.bak')
            assert(os.rename(path..'.profile.tmp',path..'.profile'))
            os.remove(path..'.profile.bak')
        end)
        if ok then last_profile=text else state.profile_error=tostring(why)end
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
        assert(api.module_hash(game)==build.game_sha256 and api.module_hash(exe)==build.exe_sha256,'Unsupported game build')
        adapter=native.new(api,game,exe,signatures,dependencies)
        cache=policy.new(adapter,options)
        if images and options.images then
            local image_adapter=image_native.new(api,game,exe,image_signatures)
            image_cache=images.new(image_adapter,options)
        end
        local learned,valid=profile.decode(read_file('.profile',65536),build_key)
        if not valid then learned=profile.decode(read_file('.profile.bak',65536),build_key)end
        for _,item in ipairs(learned)do cache:remember(item)end
    end
    local function frame(dt)
        state.frames=state.frames+1
        if not stopped then load_settings()end
        if stopped or not options.enabled then state.status=stopped and state.status or 'disabled_by_config';log(false);return end
        initialize();api.assert_thread()
        -- Presentation runs every callback, independent of the slower asset
        -- residency budget. A 50 ms image poll would itself add visible delay.
        if image_cache then image_cache:tick(state.pressure_reason~=nil)end
        elapsed=elapsed+(type(dt)=='number' and math.max(0,math.min(dt,.25)) or 0)
        if elapsed<.05 then return end
        elapsed=0
        local ok,s=pcall(adapter.snapshot,adapter)
        if not ok then
            -- Loading screens can temporarily remove managers. Retain no new
            -- leases; cleanup only through revalidated ownership.
            cleanup();state.status='waiting_for_ui';state.last_error=tostring(s);log(false);return
        end
        local free,private,commit=api.memory()
        if not s.menu or baseline_world~=s.world then baseline=private;baseline_world=s.world end
        baseline=baseline or private
        local growth=math.max(0,private-baseline)
        state.free_mib=math.floor(free/1048576);state.private_growth_mib=math.floor(growth/1048576)
        state.commit_headroom_mib=math.floor(commit/1048576)
        state.last_top=s.top;state.last_items=#s.items;state.last_active=s.active
        state.last_blocked=s.blocked
        state.pressure_reason=memory_guard:tick(api.time(),free,commit)
        cache:tick(s,api.time(),state.pressure_reason~=nil)
        state.status=cache.status
        -- Persist learned entries after menu interaction, or during shutdown.
        if not s.menu and not s.active then save(false) end
        log(false)
    end
    -- in_previous stays true when the previous update raised. failure is the
    -- status set when the mod first stopped; the shutdown status keeps it.
    local in_previous,failure=false
    -- The log keeps why and when the mod stopped itself (disabled_reason,
    -- disabled_frame); a stop happens once per session.
    local function fail(status)
        stopped=true;cleanup();state.status=status;failure=failure or status
        state.disabled_reason=status;state.disabled_frame=state.frames;log(true)
    end
    -- The previous update raised on its last call and its error reached the
    -- game unchanged. Stop once; later calls keep forwarding to it.
    local function previous_failed()
        in_previous=false
        if not stopped then fail('original_update_failed')end
    end
    local function after(dt,...)
        in_previous=false
        local worked,why=pcall(frame,dt)
        if not worked then fail('disabled: '..tostring(why))end
        return ...
    end
    -- Named once: a pcall of an inline function would allocate a closure every frame.
    local function image_before()api.assert_thread();image_cache:before()end
    update=function(dt,...)
        if in_previous then previous_failed()end
        if image_cache and not stopped then
            local ok,why=pcall(image_before)
            if not ok then fail('disabled: '..tostring(why))end
        end
        -- No pcall: the previous update's errors keep their traceback and value.
        in_previous=true
        return after(dt,previous(dt,...))
    end
    local function finish()
        if in_previous then previous_failed()end
        stopped=true;cleanup();state.status=failure and 'stopped after: '..failure or 'stopped';log(true)
    end
    shutdown=function(...)
        -- Own cleanup is protected and never raises into the shutdown chain.
        local ok,why=pcall(finish);if not ok then state.last_error='shutdown: '..tostring(why)end
        if previous_shutdown then return previous_shutdown(...)end
    end
    log(true)
end
