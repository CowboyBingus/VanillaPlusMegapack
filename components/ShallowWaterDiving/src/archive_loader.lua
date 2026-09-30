-- text: src/bingus_text.lua; locales: {en, bundled} (locales/).
return function(create_api,patch,build,text,locales)
    if rawget(_G,'ShallowWaterDive') then return end
    local state={revision=build.revision,active=false,observed=0,protected=0,
        restored=0,startup_clears=0,short_ends=0,table_moves=0}
    rawset(_G,'ShallowWaterDive',state)
    local api,game,exe,last_log
    -- The slider's texts, in the game's language when a translation has them;
    -- the translator's notes (language, refused entries) go to the log.
    local text_notes={}
    local tr=text.new(locales.en,locales.bundled,function(message)
        if #text_notes<20 then text_notes[#text_notes+1]=message end
    end)
    -- Status and counts are kept in ShallowWaterDive on every check. The log
    -- file is written on startup, after the menu registration, when the mod
    -- stops and at shutdown; routine updates only with CowboyBingusDiagnostics
    -- = true, at most every 2 s. A check builds no strings and opens no files.
    local function report(status,active,force)
        state.status=status;state.active=active
        if not force and rawget(_G,'CowboyBingusDiagnostics')~=true then return end
        local now=api and api.time and api.time() or 0
        if not force and last_log and now-last_log<2 then return end
        last_log=now
        if force then print('[ShallowWaterDiving] '..build.revision..': '..status) end
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('ShallowWaterDiving.log');if not file then return end
            file:write(build.revision..'\n'..status..'\n')
            for _,key in ipairs({'observed','protected','restored','startup_clears','short_ends','table_moves'}) do
                file:write(key..'='..state[key]..'\n')
            end
            -- Memory protection queries this session (about 0.2-0.3 ms each in game).
            file:write('protection_queries='..tostring(api and api.queries or 0)..'\n')
            if state.depth_option then file:write('depth_option='..state.depth_option..'\n') end
            for _,line in ipairs(text_notes) do file:write('text: '..line..'\n') end
            file:close()
        end)
    end
    -- Optional Mod Options Menu slider for the deepest water a dive may start
    -- in. Every addon has loaded before the first update, so one attempt there
    -- suffices; the applied value reaches the patch through on_change.
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
    local ok,why=pcall(function()
        local loader=rawget(_G,'CowboyBingusModLoader')
        assert(type(loader)=='table' and type(loader.api)=='number' and loader.api>=1
            and type(loader.version)=='number' and loader.version>=6,
            'Bingus Shared Loader loader-v5 or newer / API 1 or newer is required')
        api=create_api()
        game,exe=api.module('game.dll'),api.module(nil)
        assert(game and exe,'Required modules unavailable')
        assert(api.module_hash(game)==build.game_sha256,'Unsupported game module')
        assert(api.module_hash(exe)==build.exe_sha256,'Unsupported executable')
        assert(type(update)=='function','Game update unavailable')
    end)
    if not ok then report(tostring(why),false,true);return end
    local previous,previous_shutdown,stopped=update,shutdown,false
    local function cleanup()
        local called,restored=pcall(patch.restore,api,state.pending)
        if called and restored then state.pending=nil;return true end
        return false
    end
    local function check()
        if stopped then return end
        local called,accepted,reason,active=pcall(patch.apply,api,game,exe,state)
        if not called or not accepted then
            stopped=true
            local restored=cleanup()
            report(tostring(called and reason or accepted)..(restored and '' or '; restore_failed'),false,true)
            return
        end
        report(reason,active==true)
    end
    local function after(called,...)
        if not called then
            stopped=true
            report(cleanup() and 'stopped_after_update_error' or 'restore_failed',false,true)
            error((...),0)
        end
        -- The after-update boundary is checked while a lease or retry is in
        -- progress or a local avatar exists (then the patch's idle gate costs
        -- one read). Which boundary first sees a new dive is unknown
        -- (docs/TECHNICAL.md), so both watch whenever a dive can start; without
        -- a local avatar none can start before the next update.
        if state.pending or state.retry_start or state.gate_controller then check() end
        return ...
    end
    update=function(...)
        if not state.depth_option then
            -- A failing menu must never reach the game's update chain.
            local called,result=pcall(register_depth_option)
            state.depth_option=called and result or 'failed: '..tostring(result)
            report(state.status,state.active,true)
        end
        check();return after(pcall(previous,...))
    end
    shutdown=function(...)
        stopped=true
        report(cleanup() and 'stopped' or 'restore_failed',false,true)
        if previous_shutdown then return previous_shutdown(...) end
    end
    report('waiting_for_mission',false,true)
end
