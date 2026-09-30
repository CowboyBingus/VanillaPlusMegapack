return function(create_api,mission,resolve,roster,roster_data,model,panel,build,presentation,text,locales)
    if rawget(_G,'EnemyIntelligence') then return end
    local state = {revision=build.revision,status='starting',reads=0,frames=0,failures=0}
    rawset(_G,'EnemyIntelligence',state)
    local api,source,surface,current,view,game,tr,font
    local forecasts = roster.new(roster_data)
    local started, elapsed = false, 0
    local selected_key,selected_screen,controller_matches
    local previous = update
    -- Translation notes (language, refused entries) stay under the status line.
    local notes = {}
    local function write_log()
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('EnemyIntelligence.log')
            if file then
                file:write(build.revision..'\n'..state.status..'\n')
                for _,line in ipairs(notes) do file:write(line..'\n') end
                file:close()
            end
        end)
    end
    local function report(message)
        if state.status == message then return end
        state.status = message
        print('[EnemyIntelligence] '..message)
        write_log()
    end
    local function note(message)
        if #notes >= 40 then return end
        notes[#notes+1] = message
        write_log()
    end
    -- The game's Text Language (5 reads). Read when the panel first appears
    -- and whenever the native font changes, which is what a language change
    -- does; texts follow at the next 0.5 s re-sample. api.read takes pointers,
    -- bingus_text passes numbers.
    local function read_at(address,size)
        return api.read(require('ffi').cast('uint8_t *',address),size)
    end
    local function observe_language(anchor)
        if anchor.font == font then return end
        font = anchor.font
        local tag,code = text.observe(read_at,game)
        note('text language: '..(tag and (tag..' (game setting '..code..')') or (text.language()..' (Steam)')))
    end
    local function initialize()
        if started then return source ~= nil end
        started = true
        local ok,why = pcall(function()
            api = create_api()
            local exe
            game,exe = assert(api.module('game.dll')),assert(api.module(nil))
            assert(api.module_hash(game) == build.game_sha256, 'Unsupported game module')
            assert(api.module_hash(exe) == build.exe_sha256, 'Unsupported executable')
            assert(stingray and stingray.Gui and stingray.World, 'Game GUI unavailable')
            tr = text.new(locales.en,locales.bundled,note)
            source = mission.new(api,game,resolve)
            surface = panel.new(stingray)
            view = presentation.new(api,game)
        end)
        if not ok then
            source = nil
            report('disabled: '..tostring(why))
            return false
        end
        report('ready')
        return true
    end
    local function reset_selection()
        current,selected_key,selected_screen,controller_matches = nil,nil,nil,nil
        elapsed = 0
        state.key,state.screen,state.complete = nil,nil,false
    end
    local function select(descriptor)
        if not descriptor then
            current,selected_key,controller_matches = nil,nil,false
            state.key,state.complete = nil,false
            elapsed = 0
            return
        end
        local changed = selected_key ~= descriptor.key or selected_screen ~= descriptor.screen
        if changed then
            if selected_screen and selected_screen ~= descriptor.screen then surface:clear() end
            current = nil
        end
        -- Check identity every frame. Resolve immediately when the controller
        -- catches up, then poll unresolved inputs at a bounded 100 ms cadence.
        if changed or descriptor.controller_matches and not controller_matches then elapsed = 0.5 end
        controller_matches = descriptor.controller_matches == true
        if not controller_matches then current = nil end
        selected_key,selected_screen = descriptor.key,descriptor.screen
        state.key,state.screen = selected_key,selected_screen
    end
    local function frame(dt)
        if not initialize() then return end
        state.frames = state.frames+1
        local screen = source:screen()
        local anchor = screen and view:sample(screen)
        if not anchor then
            reset_selection()
            surface:clear()
            report('hidden')
            return
        end
        if selected_screen and selected_screen~=screen then
            reset_selection()
            surface:clear()
        end
        observe_language(anchor)
        selected_screen,state.screen = screen,screen
        local descriptor,hovered = source:descriptor(screen)
        -- Native selection ends before the card's fade. Hide immediately on
        -- unhover, but retain the frame while a hovered mission is loading.
        if anchor.client and (hovered==false or hovered==nil and not anchor.active) then
            reset_selection()
            surface:clear()
            report('hidden')
            return
        end
        select(descriptor)
        elapsed = elapsed + math.max(0,dt or 0)
        if controller_matches and elapsed >= (current and 0.5 or 0.1) then
            elapsed = 0
            local snapshot = source:sample(screen)
            state.reads = state.reads+1
            if source:screen() ~= screen then
                reset_selection()
                surface:clear()
                report('hidden')
                return
            end
            local latest,latest_hovered = source:descriptor(screen)
            if anchor.client and latest_hovered==false then
                reset_selection()
                surface:clear()
                report('hidden')
                return
            end
            select(latest)
            current = nil
            -- Publish the report only from a complete snapshot belonging to
            -- the selection both before and after reads.
            if snapshot and snapshot.complete == true and snapshot.controller_matches == true and controller_matches
                and snapshot.key == descriptor.key and snapshot.key == selected_key
                and snapshot.screen == screen and selected_screen == screen then
                -- The roster is recomputed only when the mission inputs change;
                -- texts only when the language or the installed packs change.
                tr:refresh()
                current = model.make(snapshot,forecasts:report(snapshot,snapshot.zone,snapshot.war),roster_data,tr)
            end
        end
        state.complete = current ~= nil
        if not current then
            surface:suspend(anchor)
            report('waiting for mission data '..screen..' '..(selected_key or 'preview loading'))
            return
        end
        local drawn = surface:show(current,dt,anchor)
        report((drawn and 'visible ' or 'waiting for GUI ')..screen..' '..current.key..' composition rules resolved')
    end
    local function after(dt,...)
        local ok,why = pcall(frame,dt)
        if not ok then
            state.failures = state.failures+1
            reset_selection()
            if surface then pcall(function() surface:clear() end) end
            report('hidden: '..tostring(why))
        end
        return ...
    end
    update = function(dt,...)
        if previous then return after(dt,previous(dt,...)) end
        after(dt)
    end
    local old_shutdown = shutdown
    shutdown = function(...)
        if surface then pcall(function() surface:clear() end) end
        if old_shutdown then return old_shutdown(...) end
    end
end
