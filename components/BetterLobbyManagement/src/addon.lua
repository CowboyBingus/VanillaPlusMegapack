-- Startup checks, the escape-menu buttons, squad messages, the Galactic Map
-- scanner, Mod Options Menu settings and the update hook. C: squad chat
-- (src/chat.lua). S: the scanner's recharge (src/scanner.lua). B: CANCEL SOS
-- (src/sos.lua). T: texts and translations (src/bingus_text.lua) with the
-- locales ({en, bundled}). build: {version, game_sha256, exe_sha256, diag}.
-- D: the diagnostic recorder (src/diag.lua), in diagnostic test builds only.
return function(create_api, G, L, R, M, C, S, B, T, locales, build, D)
    if rawget(_G, 'BetterLobbyManagement') then return end
    local state = {version = build.version, status = 'starting', menu = 'pending', options = 'pending',
                   errors = 0, revision = 0}
    rawset(_G, 'BetterLobbyManagement', state)

    local loader = rawget(_G, 'CowboyBingusModLoader')
    local log_file
    if type(loader) == 'table' and type(loader.open_log) == 'function' then
        pcall(function() log_file = loader.open_log('BetterLobbyManagement.log') end)
    end
    local clock = 0
    local function note(message)
        if log_file then
            pcall(function() log_file:write(string.format('[%9.2f] %s\n', clock, message)); log_file:flush() end)
        end
    end
    -- Every text the player sees, in the game's language when a translation
    -- has it (locales/, translation packs), else English.
    local tr = T.new(locales.en, locales.bundled, function(message) note('text: ' .. message) end)

    -- Startup refusals carry a plain reason (LuaJIT's assert would prefix a file position).
    local function expect(condition, message) if not condition then error(message, 0) end end
    local api, game, exe, natives
    local verified, reason = pcall(function()
        api = create_api()
        game = api.module('game.dll')
        exe = api.module(nil)
        expect(game and exe, 'game modules unavailable')
        expect(api.module_sha256(game) == build.game_sha256, 'unsupported game.dll build')
        expect(api.module_sha256(exe) == build.exe_sha256, 'unsupported helldivers2.exe build')
        natives = G.bind(api, game, exe)
    end)
    if not verified then
        state.status = 'unsupported: ' .. tostring(reason)
        note('Better Lobby Management ' .. build.version .. ' inactive: ' .. tostring(reason))
        return
    end
    state.api = api
    local lobby = L.new(api, game, G, natives, state, note)
    lobby.text = tr
    -- The game's Text Language (5 guarded reads), logged when it changes.
    local language
    local function observe_language()
        local tag, code = T.observe(api.read_bytes, game)
        local seen = tag and (tag .. ' (game setting ' .. code .. ')') or (T.language() .. ' (Steam)')
        if seen ~= language then
            language = seen
            note('text language: ' .. seen)
        end
    end
    local region = R.new(api, game, natives, state, note)
    local region_ok, region_why = region.verify()

    -- The Galactic Map scanner's recharge (formerly Fast Lobby Scanner), after
    -- its own code checks; a mismatch disables only the scanner. Its status
    -- table is state.scanner; a log line only when its revision moves.
    local scanner, scanner_why, scanned = nil, 'not built in', nil
    state.scanner = {}
    if S then
        scanner_why = nil
        for _, code in ipairs(S.CODE) do
            if api.bytes(game + code.rva, #code.bytes) ~= code.bytes then
                scanner_why = code.name .. ' changed'
                break
            end
        end
        if not scanner_why then scanner = S.new(api, game, state.scanner) end
    end
    local function scanner_summary()
        local sc = state.scanner
        return string.format('scanner %s: setting %s s, game %s s, field %s s; writes %d, game rewrites %d, '
            .. 'countdowns shortened %d', tostring(sc.status), tostring(sc.setting), tostring(sc.game_value),
            tostring(sc.applied), sc.writes or 0, sc.refreshes or 0, sc.shortened or 0)
    end

    -- The escape-menu buttons: their natives and the code they depend on.
    local menu, menu_why
    do
        local menu_natives, ok = {}, true
        for name, native in pairs(M.NATIVES) do
            if api.bytes(game + native.rva, #native.bytes) ~= native.bytes then
                ok, menu_why = false, name .. ' changed'
                break
            end
            menu_natives[name] = api.native(native.type, game + native.rva)
        end
        if ok then
            menu = M.new(api, game, menu_natives, state, note)
            local code_ok, why = menu.verify()
            if not code_ok then menu, menu_why = nil, why end
        end
    end
    state.menu = menu and 'ready' or 'disabled: ' .. menu_why

    -- CANCEL SOS, after its own code checks; a mismatch disables only it.
    local sos, sos_why = nil, 'not built in'
    if B then
        local candidate = B.new(api, game, G, state, note)
        local ok, why = candidate.verify()
        if ok then sos = candidate else sos_why = why end
    end
    state.sos = sos and 'ready' or 'unavailable: ' .. sos_why
    state.status = 'ready'
    -- Kicks are the game's own player-menu KICK, run by the game in its own
    -- update (any other kick left the kicked player's Helldiver behind and
    -- crashed the host; see docs/TECHNICAL.md).
    lobby.kick_mode = 'game'
    if menu then
        lobby.game_kicker = function(lo, hi) return menu.game_kick(menu.screen(), lo, hi) end
        lobby.menu_closer = menu.close
    end

    -- Diagnostic test builds: the kick timeline recorder (read-only).
    local diag
    if D and build.diag then
        local recorder = D.new(api, game, exe, G, note)
        local ok, why = recorder.verify()
        if ok then
            diag, lobby.observer = recorder, recorder
            -- The host's-own-lobby control search proved the search in v0.4-diag5;
            -- it is off now because it delayed the successor's search.
            lobby.verbose = true
        else
            note('diag: recorder disabled: ' .. why)
        end
        state.diag = ok and 'recording' or 'disabled: ' .. why
    end

    -- Squad messages before the kicks: for PROMOTE the game's own new squad
    -- leader notice, for DISBAND a line of the game's text chat. Without them
    -- the actions still run.
    local chat, chat_why = nil, 'not built in'
    if C then
        local candidate = C.new(api, game, G, note)
        local ok, why = candidate.verify()
        if ok then chat = candidate else chat_why = why end
    end
    state.chat = chat and 'ready' or 'unavailable: ' .. chat_why
    local function set_messages(on)
        lobby.announcer = (on and chat) and function(text) return chat.send(text, diag ~= nil) end or nil
        lobby.leader_notice = (on and chat) and function(lo, hi) return chat.new_leader(lo, hi, diag ~= nil) end or nil
    end
    set_messages(true)

    -- Settings (Mod Options Menu, optional). Texts are keys in locales/en.lua;
    -- 'On' and 'Off' are the game's own words, which the menu translates.
    local OPTIONS = {
        {id = 'better_lobby_management.region', key = 'region', texts = {type = 'choice',
            label = 'option.region.label', choices = {'option.region.default', 'option.region.continent'},
            default = 1, description = 'option.region.description'}},
        {id = 'better_lobby_management.messages', key = 'messages', texts = {type = 'choice',
            label = 'option.messages.label', native_choices = {'On', 'Off'}, default = 1,
            description = 'option.messages.description'}},
        {id = 'better_lobby_management.scanner_seconds', key = 'scanner', texts = {type = 'slider',
            label = 'option.scanner.label', min = S and S.MIN_SECONDS or 5, max = S and S.MAX_SECONDS or 20,
            step = 1, default = S and S.DEFAULT_SECONDS or 5, description = 'option.scanner.description'}},
    }
    local KICK_TESTS = {{'game', 'Game Kick'}, {'render', 'Kick From Render'}, {'message', 'Message First'},
                        {'hold', 'Hold Unloads'}, {'plain', 'Plain Kick (v0.3)'}}
    local NOTICES = {{'leader', 'Squad Leader Line'}, {'chat', 'Chat Line'}}
    if build.diag then
        local choices = {}
        for i, test in ipairs(KICK_TESTS) do choices[i] = test[2] end
        lobby.kick_mode = KICK_TESTS[1][1]
        OPTIONS[#OPTIONS + 1] = {id = 'better_lobby_management.kick_test', key = 'kick_test', spec = {type = 'choice',
            label = 'Kick Test', mod = 'Better Lobby Management', choices = choices, default = 1,
            description = 'Test build only. Game Kick makes the game run its own player-menu KICK. Kick From Render '
                .. 'and Message First are test 2\'s kicks, Hold Unloads test 1\'s. Plain Kick is v0.3\'s kick and may '
                .. 'crash the host.'}}
        lobby.notice_mode = NOTICES[1][1]
        OPTIONS[#OPTIONS + 1] = {id = 'better_lobby_management.promote_notice', key = 'promote_notice', spec = {
            type = 'choice', label = 'Promote Notice', mod = 'Better Lobby Management', default = 1,
            choices = {NOTICES[1][2], NOTICES[2][2]},
            description = 'Test build only. Squad Leader Line sends the game\'s own "<name> is the new squad leader" '
                .. 'notice before PROMOTE kicks the new host (the release\'s message); Chat Line sends a chat message '
                .. 'from you.'}}
    end
    local function apply_setting(key, value)
        if type(value) ~= 'number' then return end
        if key == 'kick_test' then
            local test = KICK_TESTS[value] or KICK_TESTS[1]
            lobby.kick_mode = test[1]
            note('kick test: ' .. test[2])
        elseif key == 'promote_notice' then
            local notice = NOTICES[value] or NOTICES[1]
            lobby.notice_mode = notice[1]
            note('promote notice: ' .. notice[2])
        elseif key == 'scanner' then
            if scanner then scanner.set_setting(value) end
        elseif key == 'messages' then
            set_messages(value ~= 2)
        elseif key == 'region' then
            if region_ok then
                region.set_mode(value)
            elseif value == 2 then
                note('nearby lobbies unavailable: ' .. region_why)
            end
        end
    end
    -- Mod Options Menu v1.1 and later (version 2) take texts as functions and
    -- call them whenever they build the MODS page, so the texts follow the
    -- game's language. v1.0 takes strings with byte limits: a translation
    -- that does not fit stays English there.
    local function option_text(options_menu, key, bytes)
        if (tonumber(options_menu.version) or 1) >= 2 then return function() return tr(key) end end
        local text = tr(key)
        return #text <= bytes and text or tr.english[key]
    end
    local function spec_of(option, options_menu)
        if option.spec then
            -- Test-build options: English texts under the same (translated) mod name.
            local spec = {}
            for field, value in pairs(option.spec) do spec[field] = value end
            spec.mod = option_text(options_menu, 'option.mod', 40)
            return spec
        end
        local texts = option.texts
        local spec = {type = texts.type, default = texts.default, min = texts.min, max = texts.max, step = texts.step,
            mod = option_text(options_menu, 'option.mod', 40), label = option_text(options_menu, texts.label, 64),
            description = option_text(options_menu, texts.description, 400), choices = texts.native_choices}
        if texts.choices then
            spec.choices = {}
            for i, key in ipairs(texts.choices) do spec.choices[i] = option_text(options_menu, key, 48) end
        end
        return spec
    end
    local function register_options()
        local options_menu = rawget(_G, 'ModOptionsMenu')
        if type(options_menu) ~= 'table' or options_menu.api ~= 1 then return 'not installed (defaults in use)' end
        for _, option in ipairs(OPTIONS) do
            local ok, why = options_menu.register_option(option.id, spec_of(option, options_menu))
            if not ok then return 'not registered: ' .. tostring(why) end
            apply_setting(option.key, options_menu.get(option.id))
            options_menu.on_change(option.id, function(value) apply_setting(option.key, value) end)
        end
        return 'registered'
    end

    -- Idle gate: the context pointer and the peer count answer "could an action
    -- run?". Hosting a squad, the escape menu is looked at; alone, CANCEL SOS
    -- is the only action, so the mode is looked at first (see offer_screen).
    local gate = {ctx = 0}
    local function hosts(ctx)
        return api.load32(ctx + G.HOST) == api.load32(ctx + G.LOCAL)
            and api.load32(ctx + G.HOST + 4) == api.load32(ctx + G.LOCAL + 4)
    end
    local function hosting_squad()
        local ctx = G.context(api, game, gate)
        if ctx == 0 or api.load32(ctx + G.PEER_COUNT) < 2 then return false end
        return hosts(ctx)
    end

    -- The successor: the squad member whose player menu the host opened last,
    -- else the automatic choice. Button and dialog texts are rebuilt only when
    -- the mode, the squad, that choice or the SOS offer changes.
    local chosen = nil
    local shown = {mode = -1, count = -1, peers = {}, chosen = nil, target = nil, sos = false}
    local offer, order, dialogs = {}, {}, {}

    -- The open escape screen when an action could be offered, else 0. Alone,
    -- that is CANCEL SOS: in a mission, while the menu is open and an SOS is
    -- on, and until the button is gone again (the game rebuilds its list when
    -- players come and go, not when the SOS stops).
    local function offer_screen()
        local ctx = G.context(api, game, gate)
        if ctx == 0 then return 0 end
        if api.load32(ctx + G.PEER_COUNT) < 2 then
            if not sos then return 0 end
            local game_state = api.load64(game + G.GAME_STATE_PTR)
            if game_state == 0 or api.load32(game_state + G.MODE) ~= G.MODE_MISSION then return 0 end
            local screen = menu.screen()
            if screen == 0 or not (shown.sos or sos.active()) or not hosts(ctx) then return 0 end
            return screen
        end
        if not hosts(ctx) then return 0 end
        return menu.screen()
    end
    local ORDER_SHIP, ORDER_SOS = {'disband', 'promote'}, {'cancel_sos'}
    local function changed(snap, sos_state)
        if shown.mode ~= snap.mode or shown.count ~= snap.peer_count or shown.chosen ~= chosen
            or shown.sos ~= sos_state then
            return true
        end
        for i = 1, snap.peer_count do
            local peer, seen = snap.peers[i], shown.peers[i]
            if not seen or seen.lo ~= peer.lo or seen.hi ~= peer.hi then return true end
        end
        return false
    end
    -- sos_state: the privacy setting while CANCEL SOS can be offered, else false.
    local function rebuild_offer(snap, sos_state)
        tr:refresh()
        shown.mode, shown.count, shown.chosen, shown.sos = snap.mode, snap.peer_count, chosen, sos_state
        shown.generation = tr.generation -- the texts' language, to rebuild after a change
        for i = 1, snap.peer_count do shown.peers[i] = {lo = snap.peers[i].lo, hi = snap.peers[i].hi} end
        offer, order, dialogs, shown.target = {}, {}, {}, nil
        if sos_state then
            order = ORDER_SOS
            offer.cancel_sos = tr('button.cancel_sos')
            dialogs.cancel_sos = {title = tr('dialog.cancel_sos.title'), body = B.body(sos_state, tr)}
            return
        end
        if snap.mode ~= G.MODE_SHIP then return end
        local target = chosen and lobby.choose_successor(snap, chosen)
        if chosen and not target then chosen, shown.chosen = nil, nil end
        target = target or lobby.choose_successor(snap, nil)
        shown.target = target
        if not target then return end
        local name = G.names(api, game)[G.peer_key(target.lo, target.hi)]
            or tr('player.unknown', {id = api.u64_hex(target.lo, target.hi)})
        -- Upper case for every script the game's fonts carry, not only a-z.
        local upper = T.upper(name)
        -- Short: the dialog box holds about three lines. Without a pick, say
        -- the player was chosen for the host (the README says how).
        order = ORDER_SHIP
        offer.disband, offer.promote = tr('button.disband'), tr('button.promote', {name = upper})
        dialogs.disband = {title = tr('dialog.disband.title'), body = tr('dialog.disband.body')}
        dialogs.promote = {title = tr('dialog.promote.title', {name = upper}),
            body = tr(chosen and 'dialog.promote.body' or 'dialog.promote.body_automatic', {name = name})}
    end
    local function run_action(action)
        local target = shown.target and {lo = shown.target.lo, hi = shown.target.hi}
        if action == 'disband' then return lobby.disband(clock) end
        if action == 'promote' then return lobby.promote(target, clock) end
        if action == 'cancel_sos' then return sos.cancel(clock) end
    end

    -- Lua entry points (console or other addons). target: {lo, hi} or nil.
    function state.disband() return lobby.disband(clock) end
    function state.promote(target) return lobby.promote(target, clock) end
    function state.cancel() return lobby.cancel('requested') end
    function state.cancel_sos()
        if not sos then return false, state.sos end
        return sos.cancel(clock)
    end

    local step
    local menu_seen = false
    local function run(dt)
        clock = clock + (dt or 0)
        if scanner then
            scanner.check() -- two direct loads while nothing changed
            if state.scanner.revision ~= scanned then
                scanned = state.scanner.revision
                note(scanner_summary())
            end
        end
        if diag then diag.frame(clock, hosting_squad) end
        -- A cancelled SOS stays off: the game lists it again when a player leaves.
        if sos and sos.cancelled() then sos.keep(clock) end
        if lobby.holding() then lobby.tick(clock) end
        if lobby.arrival then lobby.check_arrival(clock) end -- once, after a promote's move
        if lobby.busy() then
            lobby.step(clock)
        elseif menu then
            local screen = offer_screen()
            if screen == 0 then menu_seen = false end
            if screen ~= 0 then
                if not menu_seen then
                    -- The game's Text Language can change in the escape menu's
                    -- own OPTIONS tab: read it once each time the menu opens
                    -- with something to offer, and rebuild the texts if the
                    -- language or the installed translations changed.
                    menu_seen = true
                    observe_language()
                    tr:refresh()
                    if tr.generation ~= shown.generation then shown.mode = -1 end
                end
                local snap = lobby.snapshot()
                if snap then
                    local sos_state = sos and sos.offer(snap) or false
                    if changed(snap, sos_state) then rebuild_offer(snap, sos_state) end
                    local lo, hi = menu.step(screen, snap.local_lo, snap.local_hi, offer, order, dialogs, run_action)
                    if lo and (not chosen or chosen.lo ~= lo or chosen.hi ~= hi) then
                        chosen = {lo = lo, hi = hi}
                    end
                end
                if diag then menu.trace(screen) end
            end
        end
        if lobby.ui_pending() then lobby.ui_step(clock) end
        region.step()
    end
    step = function(dt)
        -- Translations register when their addon loads, before this first
        -- update; the language decides the Mod Options Menu texts below.
        observe_language()
        local called, result = pcall(register_options)
        state.options = called and result or 'failed: ' .. tostring(result)
        note('Mod Options Menu: ' .. state.options)
        step = run
        return run(dt)
    end

    -- An error stops the mod for the session: any action is cancelled, the
    -- region flags are put back and the game's own update keeps running.
    local previous_update, previous_shutdown = rawget(_G, 'update'), rawget(_G, 'shutdown')
    local traceback = debug.traceback
    local stopped = false
    local function stop(err)
        stopped = true
        state.errors = state.errors + 1
        state.status = 'stopped after error'
        pcall(lobby.cancel, 'error')
        pcall(lobby.release_hold, 'error')
        local restored = pcall(region.restore)
        if scanner then pcall(scanner.stop, 'stopped_after_error') end
        if sos and sos.cancelled() then note('CANCEL SOS: no longer kept off; a player leaving lists the SOS again') end
        note('Error: ' .. tostring(err))
        note('Better Lobby Management stopped for this session' .. (restored and '; region flags restored' or ''))
    end
    update = function(dt)
        if not stopped then
            local ok, err = xpcall(step, traceback, dt)
            if not ok then stop(err) end
        end
        if type(previous_update) == 'function' then return previous_update(dt) end
    end
    -- Diagnostic builds: the Kick From Render test runs its kicks here, after
    -- the game's own update in the same frame.
    if build.diag then
        local previous_render = rawget(_G, 'render')
        local function render_kicks() lobby.render_step(clock) end
        render = function(...)
            if not stopped then
                local ok, err = xpcall(render_kicks, traceback)
                if not ok then stop(err) end
            end
            if type(previous_render) == 'function' then return previous_render(...) end
        end
    end
    shutdown = function(...)
        pcall(lobby.release_hold, 'shutdown')
        local restored = region.mode() == 2 and region.restore() or 0
        note(string.format('Shutdown: %d actions; region flags restored %d; page checks %d; errors %d%s%s',
            state.actions or 0, restored, api.queries, state.errors, scanner and '; ' .. scanner_summary() or '',
            sos and string.format('; SOS cancels %d, re-arms caught %d (%d already posted)', state.sos_cancels,
                state.sos_rearms, state.sos_leaks) or ''))
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end
    note('Better Lobby Management ' .. build.version .. ' ready: game code and natives verified; menu '
        .. state.menu .. (region_ok and '' or '; Lobby Region disabled: ' .. region_why)
        .. '; squad messages ' .. state.chat .. '; scanner ' .. (scanner and 'ready' or 'disabled: ' .. scanner_why)
        .. '; CANCEL SOS ' .. state.sos .. (state.diag and '; diagnostics ' .. state.diag or ''))
end
