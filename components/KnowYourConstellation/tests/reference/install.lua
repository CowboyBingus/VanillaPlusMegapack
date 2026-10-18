-- modules: the mod's chunks (create_api, mission, resolve, roster, roster_data,
-- model, panel, presentation, text, locales), its build {revision,
-- game_sha256, exe_sha256}, and the vendored Bingus Shared Runtime core
-- (runtime) and read side (runtime_memory).
return function(modules)
    if rawget(_G,'EnemyIntelligence') then return end
    local create_api,mission,resolve,roster = modules.create_api,modules.mission,modules.resolve,modules.roster
    local roster_data,model,panel,build = modules.roster_data,modules.model,modules.panel,modules.build
    local presentation,text,locales = modules.presentation,modules.text,modules.locales
    local runtime,runtime_memory = modules.runtime,modules.runtime_memory
    -- failures: the mod's own frame errors this session; pending: frames that
    -- met an expected transient state (never counted as errors). The update
    -- guard's counters and first failure are in state.guard (its status).
    local state = {revision=build.revision,status='starting',reads=0,frames=0,failures=0,pending=0}
    rawset(_G,'EnemyIntelligence',state)
    local api,source,surface,current,view,game,tr,font,guard
    local forecasts = roster.new(roster_data)
    local started, elapsed = false, 0
    local selected_key,selected_screen,controller_matches
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
    -- A refusal to start (unsupported game) stops the guard: it is the
    -- session's first failure, and no frame runs again.
    local function refuse(why)
        guard.stop('disabled: '..tostring(why))
    end
    -- The game's Text Language (5 reads). Read when the panel first appears
    -- and whenever the native font changes, which is what a language change
    -- does; texts follow at the next 0.5 s re-sample. Both take number
    -- addresses; the reads return strings.
    local function read_at(address,size)
        return api.read(address,size)
    end
    local function observe_language(anchor)
        if anchor.font == font then return end
        font = anchor.font
        local tag,code = text.observe(read_at,game)
        note('text language: '..(tag and (tag..' (game setting '..code..')') or (text.language()..' (Steam)')))
    end
    -- Creates the readers and the panel; raises when the game or its build is
    -- not supported. The build check hashes each module file at most once per
    -- session for every mod on the runtime (BingusRuntime.hashes).
    local function start()
        local supported,why = runtime_memory.new(runtime).verify_build({exe_sha256=build.exe_sha256,
            game_sha256=build.game_sha256})
        if not supported then error(why,0) end
        api = create_api()
        game = assert(api.module('game.dll'),'game modules unavailable')
        assert(stingray and stingray.Gui and stingray.World, 'Game GUI unavailable')
        tr = text.new(locales.en,locales.bundled,note)
        source = mission.new(api,game,resolve)
        surface = panel.new(stingray)
        view = presentation.new(api,game)
    end
    local function initialize()
        if started then return source ~= nil end
        started = true
        local ok,why = pcall(start)
        if not ok then
            source = nil
            refuse(why)
            return false
        end
        report('ready')
        return true
    end
    -- Tables the readers fill again every frame: the native panel, the
    -- selection before and after a sample, and the sample itself. Nothing
    -- keeps them past the frame, so frames allocate nothing for them.
    local anchor_box,selection_before,selection_after,sampled = {},{},{},{}
    -- An unchanged refresh reuses the last roster report and model.
    local function same_tags(a,b)
        if #a ~= #b then return false end
        for i = 1,#a do
            if a[i] ~= b[i] then return false end
        end
        return true
    end
    local function copy_tags(into,from)
        local n = #from
        for i = 1,n do into[i] = from[i] end
        for i = #into,n+1,-1 do into[i] = nil end
    end
    -- A weight table equal to the kept copy (present: whether one was kept).
    local function same_weights(kept,present,weights)
        if not weights or not present then return not weights and not present end
        local n = 0
        for family,value in pairs(weights) do
            if kept[family] ~= value then return false end
            n = n+1
        end
        for _ in pairs(kept) do n = n-1 end
        return n == 0
    end
    -- Copies weights into kept (emptied first); true when there were any.
    local function keep_weights(kept,weights)
        for family in pairs(kept) do kept[family] = nil end
        if not weights then return false end
        for family,value in pairs(weights) do kept[family] = value end
        return true
    end
    -- forecasts:report returns its cached report for the same faction,
    -- difficulty, tag set and weight modifiers. The last call's inputs are
    -- kept here (copied), so inputs exactly equal to them get that report
    -- before the roster builds its cache key again.
    local last = {tags={},zone={},war={}}
    local function roster_report(snapshot)
        local zone,war = snapshot.zone,snapshot.war
        if last.report and last.faction == snapshot.faction and last.difficulty == snapshot.difficulty
            and same_tags(last.tags,snapshot.tags) and same_weights(last.zone,last.has_zone,zone)
            and same_weights(last.war,last.has_war,war) then
            return last.report
        end
        local report = forecasts:report(snapshot,zone,war)
        last.report,last.faction,last.difficulty = report,snapshot.faction,snapshot.difficulty
        copy_tags(last.tags,snapshot.tags)
        last.has_zone,last.has_war = keep_weights(last.zone,zone),keep_weights(last.war,war)
        return report
    end
    -- The model depends only on the report, the mission key, screen and tags
    -- and the translator's texts (tr.generation grows when they change).
    local made = {tags={}}
    local function forecast(snapshot)
        tr:refresh()
        local report = roster_report(snapshot)
        if made.model and made.report == report and made.key == snapshot.key and made.screen == snapshot.screen
            and made.generation == tr.generation and same_tags(made.tags,snapshot.tags) then
            return made.model
        end
        made.model = model.make(snapshot,report,roster_data,tr)
        made.report,made.key,made.screen,made.generation = report,snapshot.key,snapshot.screen,tr.generation
        copy_tags(made.tags,snapshot.tags)
        return made.model
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
    local function hide(message)
        reset_selection()
        surface:clear()
        report(message)
    end
    -- Publish a report only from a complete snapshot belonging to the
    -- selection both before and after reads.
    local function publishable(snapshot,descriptor,screen)
        return snapshot and snapshot.complete == true and snapshot.controller_matches == true and controller_matches
            and snapshot.key == descriptor.key and snapshot.key == selected_key
            and snapshot.screen == screen and selected_screen == screen
    end
    -- The re-sample of a selected mission. False when the panel had to hide.
    local function refresh(screen,anchor,descriptor)
        elapsed = 0
        local snapshot = source:sample(screen,sampled)
        state.reads = state.reads+1
        if source:screen() ~= screen then
            hide('hidden')
            return false
        end
        local latest,latest_hovered = source:descriptor(screen,selection_after)
        if anchor.client and latest_hovered==false then
            hide('hidden')
            return false
        end
        select(latest)
        current = nil
        if publishable(snapshot,descriptor,screen) then
            -- The roster is recomputed only when the mission inputs change;
            -- texts only when the language or the installed packs change.
            current = forecast(snapshot)
        end
        return true
    end
    -- The refresh runs twice a second: kept interpreted like the mission
    -- reader's sample, it adds no traces to the game's shared code cache.
    if jit and jit.off then
        for _,fn in ipairs({same_tags,copy_tags,same_weights,keep_weights,roster_report,forecast,publishable,refresh}) do
            jit.off(fn)
        end
    end
    -- The status draw() last reported and its inputs. The text is built again
    -- only when an input changes or another report replaced it, not on every
    -- frame the panel stays up.
    local drawn_status,drawn_phase,drawn_screen,drawn_key
    local function report_draw(phase,screen,key)
        if state.status == drawn_status and phase == drawn_phase and screen == drawn_screen and key == drawn_key then
            return
        end
        drawn_phase,drawn_screen,drawn_key = phase,screen,key
        if phase == 'waiting' then
            drawn_status = 'waiting for mission data '..screen..' '..(key or 'preview loading')
        else
            drawn_status = phase..screen..' '..key..' composition rules resolved'
        end
        report(drawn_status)
    end
    local function draw(screen,anchor,dt)
        state.complete = current ~= nil
        if not current then
            surface:suspend(anchor)
            return report_draw('waiting',screen,selected_key)
        end
        local drawn = surface:show(current,dt,anchor)
        report_draw(drawn and 'visible ' or 'waiting for GUI ',screen,current.key)
    end
    local function frame(dt)
        if not initialize() then return end
        state.frames = state.frames+1
        local screen = source:screen()
        local anchor = screen and view:sample(screen,anchor_box)
        if not anchor then return hide('hidden') end
        if selected_screen and selected_screen~=screen then
            reset_selection()
            surface:clear()
        end
        observe_language(anchor)
        selected_screen,state.screen = screen,screen
        local descriptor,hovered = source:descriptor(screen,selection_before)
        -- Native selection ends before the card's fade. Hide immediately on
        -- unhover, but retain the frame while a hovered mission is loading.
        if anchor.client and (hovered==false or hovered==nil and not anchor.active) then return hide('hidden') end
        select(descriptor)
        elapsed = elapsed + math.max(0,dt or 0)
        -- Re-sample every 0.5 s, or every 0.1 s while the report is pending.
        if controller_matches and elapsed >= (current and 0.5 or 0.1) and not refresh(screen,anchor,descriptor) then
            return
        end
        draw(screen,anchor,dt)
    end

    -- Update chain: the family's runtime guard (bingus_runtime.lua, policy in
    -- its README). The previous update runs outside pcall, so its errors reach
    -- the game unchanged. The mod's own errors count in bursts: 8 in one burst
    -- stop it, and 3600 frames without one end a burst. After an update below
    -- raised, the forecast is removed, the selection starts afresh and the mod
    -- pauses until the updates below have returned on 60 frames in a row; 8 of
    -- those failures in one burst stop it. The first failure survives shutdown.
    -- The forecast's frame runs after the previous update, as before: in the
    -- guard's `after`, with the frame time its `step` keeps.
    -- Expected transient states (the readers and the panel raise constant
    -- {pending = reason} tables: memory being rebuilt, no mission highlighted,
    -- the font not loaded yet, ...) never reach the guard: the frame hides the
    -- forecast, starts the selection afresh, reports the reason and retries on
    -- the next frame, as v4.0 did for every raised frame. Only genuine errors
    -- go on to the guard, after the forecast was removed.
    local function clear_surface()
        if surface then surface:clear() end
    end
    local function restore()
        reset_selection()
        clear_surface()
    end
    local frame_dt = 0
    local function keep_dt(dt) frame_dt = dt end
    local function waited(why)
        state.pending = state.pending+1
        pcall(restore)
        report(why.status)
    end
    -- A genuine error: the forecast is removed and the error goes on to the
    -- guard, which counts it. The first error of a burst reports its status;
    -- later ones of the burst only update it.
    local function failed(why)
        local message = tostring(why)
        state.failures = state.failures+1
        pcall(restore)
        if guard.status.errors == 0 then report('hidden: '..message) else state.status = 'hidden: '..message end
        error(why,0)
    end
    local function run()
        local ok,why = pcall(frame,frame_dt)
        if ok then return end
        if type(why) == 'table' and why.pending then return waited(why) end
        failed(why)
    end
    -- An update below raised: remove the forecast and start the selection
    -- afresh. A removal that raises stops the mod instead.
    local function pause(reason)
        restore()
        report('paused: '..reason)
    end
    -- The status of a stop names its reason ('stopped after: <reason>') from
    -- then on, so it already shows the first failure that shutdown keeps.
    local function stopped_after(reason)
        return 'stopped after: '..(reason:match('^stopped after (.*)$') or reason)
    end
    -- Once: a refusal, 8 errors in one burst, 8 failed updates below in one
    -- burst or a failed pause stopped the mod, or the game shuts down. The
    -- forecast is removed. At shutdown a session without a failure keeps its
    -- last status.
    local function stop(reason)
        if reason ~= 'shutdown' then
            pcall(restore)
            return report(stopped_after(reason))
        end
        pcall(clear_surface)
        local failure = guard.status.first_failure
        if failure then report(stopped_after(failure)) end
    end
    -- runtime.guard raises only for a second guard of this name, which the
    -- one-copy check above rules out.
    guard = runtime.guard({name='KnowYourConstellation',step=keep_dt,after=run,stop=stop,pause=pause,log=note,env=_G})
    state.guard = guard.status
    local installed,why = pcall(guard.install)
    if not installed then refuse(why) end
end
