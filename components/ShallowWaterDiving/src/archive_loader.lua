-- text: src/bingus_text.lua; locales: {en, bundled} (locales/); runtime:
-- src/bingus_runtime.lua, whose guard wraps the game's update and shutdown.
return function(create_api,patch,build,text,locales,runtime)
    if rawget(_G,'ShallowWaterDive') then return end
    local state={revision=build.revision,active=false,observed=0,protected=0,
        restored=0,startup_clears=0,short_ends=0,table_moves=0,menu_attempts=0}
    rawset(_G,'ShallowWaterDive',state)
    local api,game,exe,last_log,guard
    -- The slider's texts, in the game's language when a translation has them;
    -- the translator's notes (language, refused entries) go to the log, as do
    -- the guard's lines (an error burst, a pause, a resume, a stop).
    local text_notes,guard_notes={},{}
    local tr=text.new(locales.en,locales.bundled,function(message)
        if #text_notes<20 then text_notes[#text_notes+1]=message end
    end)
    local function write_log()
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ShallowWaterDiving.log');if not file then return end
            file:write(build.revision..'\n'..state.status..'\n')
            for _,key in ipairs({'observed','protected','restored','startup_clears','short_ends','table_moves'}) do
                file:write(key..'='..state[key]..'\n')
            end
            -- Memory protection queries this session (about 0.2-0.3 ms each in game).
            file:write('protection_queries='..tostring(api and api.queries or 0)..'\n')
            -- The update guard's pauses and its error counts (own, below) in the current burst.
            if guard then
                local g=guard.status
                file:write('pauses='..g.pauses..'\nerrors='..g.errors..'\nerrors_below='..g.lower_errors..'\n')
            end
            if state.depth_option then
                file:write('menu_attempts='..state.menu_attempts..'\ndepth_option='..state.depth_option..'\n')
            end
            -- Present only when the loader's after_startup made the registration.
            if state.menu_registration then file:write('menu_registration='..state.menu_registration..'\n') end
            for _,line in ipairs(text_notes) do file:write('text: '..line..'\n') end
            for _,line in ipairs(guard_notes) do file:write('guard: '..line..'\n') end
            file:close()
        end)
    end
    -- Status and counts are kept in ShallowWaterDive on every check. The log
    -- file is written on startup, after the menu registration, on each guard
    -- line, when the mod pauses or stops and at shutdown; routine updates only
    -- with CowboyBingusDiagnostics = true, at most every 2 s. A check builds no
    -- strings and opens no files.
    local function report(status,active,force)
        state.status=status;state.active=active
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[ShallowWaterDiving] '..build.revision..': '..status) end
        write_log()
    end
    local function guard_line(line)
        if #guard_notes<20 then guard_notes[#guard_notes+1]=line end
        print('[ShallowWaterDiving] '..build.revision..': '..line)
        write_log()
    end
    -- Optional Mod Options Menu slider for the deepest water a dive may start
    -- in; the applied value reaches the patch through on_change.
    local DEPTH_OPTION='shallow_water_diving.max_water_depth'
    -- Mod Options Menu v1.1 and later (version 2) take texts as functions and
    -- call them whenever the escape menu opens, so they follow the game's
    -- language; v1.0 takes strings with byte limits, where a translation that
    -- does not fit stays English.
    local function option_text(menu,key,bytes)
        if (tonumber(menu.version) or 1)>=2 then return function() return tr(key) end end
        local value=tr(key)
        return #value<=bytes and value or tr.english[key]
    end
    local function register_depth_option()
        local menu=rawget(_G,'ModOptionsMenu')
        if type(menu)~='table' or menu.api~=1 then return 'not installed' end
        local registered,reason=menu.register_option(DEPTH_OPTION,{type='slider',
            label=option_text(menu,'option.depth.label',64),mod=option_text(menu,'option.mod',40),
            min=patch.MIN_WATER_DEPTH,max=patch.SWIM_DEPTH,step=0.05,default=patch.MIN_WATER_DEPTH,
            description=option_text(menu,'option.depth.description',400)})
        if not registered then return 'not registered: '..tostring(reason) end
        patch.set_max_water_depth(menu.get(DEPTH_OPTION))
        menu.on_change(DEPTH_OPTION,function(depth) patch.set_max_water_depth(depth) end)
        return 'registered'
    end
    -- One registration attempt; a failing menu must never reach the game's
    -- update chain.
    local function attempt_registration()
        state.menu_attempts=state.menu_attempts+1
        local called,result=pcall(register_depth_option)
        state.depth_option=called and result or 'failed: '..tostring(result)
    end
    -- Without the loader's after_startup (below), the registration runs on the
    -- first update, then again when the menu's API table or its revision has
    -- changed (a menu that loaded late or was replaced, or one that may now
    -- accept what it refused): looked at every MENU_FRAMES updates, at most
    -- MENU_ATTEMPTS registrations in all. Once registered, or out of attempts,
    -- nothing about the menu runs per frame.
    local MENU_ATTEMPTS,MENU_FRAMES,UNSEEN=8,30,{}
    local menu_watch,menu_wait,menu_seen,menu_revision=true,0,UNSEEN,nil
    local function menu_changed()
        local menu=rawget(_G,'ModOptionsMenu')
        local revision=type(menu)=='table' and rawget(menu,'revision') or nil
        if menu==menu_seen and revision==menu_revision then return false end
        menu_seen,menu_revision=menu,revision
        return true
    end
    local function watch_menu()
        if not menu_changed() then return end
        attempt_registration()
        menu_watch=state.depth_option~='registered' and state.menu_attempts<MENU_ATTEMPTS
        report(state.status,state.active,true)
    end
    -- A loader whose capabilities include after_startup (Bingus Shared Loader
    -- v19) runs this once, after every mod of this startup has started (Mod
    -- Options Menu too, whatever the manager's order) and before the first
    -- update. The slider registers there, once; the menu is not watched on any
    -- frame. Should the loader refuse the callback, or not run it before the
    -- first update, the retry above takes over as with loader v18 (its watch
    -- stays armed until this runs, and the first update always attempts), and
    -- this does nothing once an attempt was made.
    local function register_after_startup()
        if state.menu_attempts>0 then return end
        menu_watch=false
        state.menu_registration='after_startup'
        attempt_registration()
        report(state.status,state.active,true)
    end
    -- Feature test, never a version comparison: true when the loader took the
    -- callback (it may already have run it, when startup had finished).
    local function use_after_startup()
        local loader=rawget(_G,'CowboyBingusModLoader')
        local tested,accepted=pcall(function()
            local capabilities=loader.capabilities
            if type(capabilities)~='table' or not capabilities.after_startup
                or type(loader.after_startup)~='function' then return false end
            return loader.after_startup(register_after_startup)==true
        end)
        return tested and accepted
    end
    local ok,why=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        -- Feature tests, never the internal version: API 1 and open_log (v14+).
        assert(type(loader)=='table' and loader.api==1 and type(loader.open_log)=='function',
            'Bingus Shared Loader v14 or newer (API 1 with open_log) is required')
        api=create_api()
        game,exe=api.module('game.dll'),api.module(nil)
        assert(game and exe,'Required modules unavailable')
        assert(api.module_hash(game)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(exe)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
    end)
    if not ok then report(tostring(why),false,true);return end
    -- Puts back the water record a lease changed (patch.restore checks the
    -- page again) and drops the lease once that worked.
    local function cleanup()
        local called,restored=pcall(patch.restore,api,state.pending)
        if called and restored then state.pending=nil;return true end
        return false
    end
    -- A refusal (false and a reason) stops the mod at once; the guard then
    -- runs stop below, which restores. An error goes on to the guard, which
    -- counts it: 8 in a burst stop the mod the same way. apply still runs
    -- under pcall, as in every release: called directly, its own entry would
    -- compile too (about 1.3 KB more of the shared code cache, offline in the
    -- game's lua51.dll) for no measurable time.
    local function check()
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called then error(accepted,0) end
        if not accepted then guard.stop(reason);return end
        report(reason,active==true)
    end
    -- Before the game's update, every frame while the mod runs.
    local function step()
        if menu_watch then
            menu_wait=menu_wait-1
            if menu_wait<=0 then menu_wait=MENU_FRAMES;watch_menu() end
        end
        check()
    end
    -- The after-update boundary is checked while a lease or retry is in
    -- progress or a local avatar exists (then the patch's idle gate costs
    -- one read). Which boundary first sees a new dive is unknown
    -- (docs/TECHNICAL.md), so both watch whenever a dive can start; without
    -- a local avatar none can start before the next update.
    local function after()
        if state.pending or state.retry_start or state.gate_controller then check() end
    end
    -- Once: a refusal, 8 errors in a burst or a failed pause stopped the mod,
    -- or the game shuts down. The shutdown status keeps the first failure,
    -- including an update below that raised just before it.
    local function stop(reason)
        local restored=cleanup()
        if reason~='shutdown' then report(reason..(restored and '' or '; restore_failed'),false,true);return end
        local failure=guard.status.first_failure
        report((restored and 'stopped' or 'restore_failed')..(failure and ' after: '..failure or ''),false,true)
    end
    -- An update below this mod raised (the game's or another mod's): restore
    -- as stop does and start afresh, as when the mod loads; the session counts
    -- and the game.dll constants verified this session stay. The guard skips
    -- this mod until the updates below have returned on 60 frames in a row.
    -- A restore that fails raises, and the guard stops the mod instead.
    local function pause(reason)
        if not cleanup() then error('restore_failed',0) end
        state.retry_start,state.was_dive=false,false
        state.gate_controller,state.key,state.write_check=nil,nil,nil
        report('paused: '..reason,false,true)
    end
    -- These run every frame (the menu watch every 30th while unregistered)
    -- and stay interpreted, as this loader's did before (its traces aborted
    -- in report): compiled they took 2-4 KB more of the LuaJIT code cache
    -- every mod and the game share, for no measurable time (offline in the
    -- game's lua51.dll). The patch's checks still compile.
    if jit and jit.off then
        for _,fn in ipairs({report,check,step,after,watch_menu,menu_changed}) do jit.off(fn) end
    end
    -- The previous update runs outside pcall, so its errors reach the caller
    -- unchanged (value and traceback); every argument and value passes through.
    ok,why=pcall(function()
        guard=runtime.guard({name='ShallowWaterDiving',step=step,after=after,stop=stop,pause=pause,
            log=guard_line,env=_G}).install()
    end)
    if not ok then report(tostring(why),false,true);return end
    report('waiting_for_mission',false,true)
    -- After the status exists: a loader whose startup has finished runs the
    -- callback at once, and its report needs it.
    use_after_startup()
end
