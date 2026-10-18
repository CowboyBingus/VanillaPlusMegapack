-- The idle gate (src/addon.lua step, src/menu.lua closed) against v1.2: the
-- v1.2 addon and menu (tests/reference/, copied from the v1.2 release) and the
-- current ones run side by side over the same fake games for thousands of
-- scripted frames: idle on the ship and in missions, no session, a client,
-- hosting a squad, the escape menu's actions (promote, disband, CANCEL SOS),
-- the Lua entry points, the scanner's field rewritten by the game, the Mod
-- Options Menu settings, an error below (pause and resume) and shutdown.
-- Every frame compares the game's native calls, the log lines, the update's
-- returns and the mod's status; every 50 frames the whole fake memory, the
-- texts and the labels. Then: idle frames allocate nothing, and the one
-- intended difference (a closed escape screen's state is forgotten whoever
-- closed it; v1.2 forgot it only while hosting) gives the same dialog.
-- Usage: test_idle_gate.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local Fake = dofile(tests .. 'fake_game.lua')
local Runtime = dofile(source .. '/bingus_runtime.lua')
local G = dofile(source .. '/game.lua')
local L = dofile(source .. '/lobby.lua')
local R = dofile(source .. '/region.lua')
local C = dofile(source .. '/chat.lua')
local S = dofile(source .. '/scanner.lua')
local B = dofile(source .. '/sos.lua')
local Text = dofile(source .. '/bingus_text.lua')
local ENGLISH = dofile(source .. '/../locales/en.lua')
local MENU = {current = dofile(source .. '/menu.lua'), reference = dofile(tests .. 'reference/menu.lua')}
local ADDON = {current = source .. '/addon.lua', reference = tests .. 'reference/addon.lua'}
local BUILD = {version = 'v-test', game_sha256 = 'GAME', exe_sha256 = 'EXE', runtime = Runtime}
local TANGO, CHARLIE = Fake.peer(0x01000000, 0x00000005), Fake.peer(0x0a000000, 0x00000007)

local function options_menu()
    local menu = {api = 1, registered = {}, callbacks = {}}
    function menu.register_option(id, spec) menu.registered[#menu.registered + 1] = {id = id, spec = spec}; return true end
    function menu.get() return nil end
    function menu.on_change(id, fn) menu.callbacks[id] = fn; return true end
    return menu
end

-- One addon (which: 'current' or 'reference') over a fresh fake game, with a
-- game update below it that raises while below.fail is set.
local function install(which)
    rawset(_G, 'BingusTranslations', nil)
    Text.registry().steam_language = 'en'
    local M = MENU[which]
    local world = Fake.new({G = G, R = R})
    Fake.install_config(world, R)
    Fake.install_menu(world, M)
    Fake.install_chat(world, C, G)
    Fake.install_scanner(world, S)
    Fake.install_sos(world, B, G)
    world.names[Fake.key(TANGO)], world.names[Fake.key(CHARLIE)] = 'Tango', 'Charlie'
    world.sync()
    local env = setmetatable({}, {__index = _G}); env._G = env
    local lines, below = {}, {fail = false}
    env.CowboyBingusModLoader = {api = 1, version = 17, open_log = function()
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}
    env.ModOptionsMenu = options_menu()
    env.update = function()
        if below.fail then error('below failed', 0) end
        return 'r1', nil, 'r3'
    end
    env.shutdown = function() end
    setfenv(assert(loadfile(ADDON[which])), env)()(function() return world.api end, G, L, R, M, C, S, B, Text,
        {en = ENGLISH, bundled = {}}, BUILD)
    return {env = env, world = world, lines = lines, below = below, state = env.BetterLobbyManagement}
end

-- Serialised for comparison: numbers, strings, booleans, nil and tables (keys sorted).
local function serial(value)
    if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, key in ipairs(keys) do out[#out + 1] = tostring(key) .. '=' .. serial(value[key]) end
    return '{' .. table.concat(out, ',') .. '}'
end
local STATUS_FIELDS = {'status', 'lobby', 'menu', 'sos', 'chat', 'options', 'errors', 'actions', 'sos_cancels',
                       'sos_rearms', 'sos_leaks', 'revision'}
local function status(t)
    local s = t.state
    local out = {}
    for _, field in ipairs(STATUS_FIELDS) do out[#out + 1] = tostring(s[field]) end
    for _, field in ipairs({'status', 'setting', 'game_value', 'applied', 'writes', 'refreshes', 'shortened'}) do
        out[#out + 1] = tostring(s.scanner[field])
    end
    return table.concat(out, '|')
end
local function same_table(a, b, label)
    for key, value in pairs(a) do assert(b[key] == value, label .. ' differs at ' .. tostring(key)) end
    for key, value in pairs(b) do assert(a[key] == value, label .. ' differs at ' .. tostring(key)) end
end

-- The guard calls the step under pcall from the game (C), so a trace started at
-- the step's entry aborts where it returns ("NYI: return to lower frame",
-- error 18 in the game's lua51.dll) and starts again until blacklisted, and
-- again whenever LuaJIT's 64 penalty slots have evicted it. The step now runs
-- interpreted: over 3000 idle frames no trace aborts that way in the step of
-- src/addon.lua, while v1.2's step (the control) does. The guard's update runs
-- interpreted here, as the game's C call leaves it. First in this file: a
-- fresh VM, so no earlier trace or penalty decides what compiles.
do
    if jit and jit.attach and jit.status() then
        local util = require('jit.util')
        -- "NYI: return to lower frame" is error 18 in the game's lua51.dll
        -- (2.1.0-alpha) and 16 in current LuaJIT 2.1 (lj_traceerr.h NYIRETL).
        local RETURN_TO_LOWER_FRAME = jit.version == 'LuaJIT 2.1.0-alpha' and 18 or 16
        -- Only aborts located in the step count: a trace can also abort on
        -- returning from the log's own pcall closure in note, a cold path.
        local function step_line(which)
            local n = 0
            for line in io.lines(ADDON[which]) do
                n = n + 1
                if line:find('^%s*local function step%(') then return n end
            end
            error('no step in ' .. ADDON[which])
        end
        local function addon_aborts(which)
            local t = install(which) -- fresh prototypes: no earlier penalties
            local count, line = 0, step_line(which)
            local function on_trace(what, _, func, _, code)
                if what == 'abort' and code == RETURN_TO_LOWER_FRAME and type(func) == 'function' then
                    local info = util.funcinfo(func)
                    if info.linedefined == line and (info.source or ''):find('addon.lua', 1, true) then
                        count = count + 1
                    end
                end
            end
            local function drive()
                for _ = 1, 1500 do t.env.update(0.016) end
                t.world.mode = G.MODE_MISSION; t.world.sync()
                for _ = 1, 1500 do t.env.update(0.016) end
            end
            jit.off(drive); jit.off(t.env.update)
            jit.attach(on_trace, 'trace')
            local ok, err = pcall(drive)
            jit.attach(on_trace)
            assert(ok, err)
            return count
        end
        -- The control's recordings sometimes end earlier, inside the fake game
        -- (a loop unroll limit), before they reach the step's return: up to
        -- five fresh installs.
        local control = 0
        for _ = 1, 5 do
            control = addon_aborts('reference')
            if control > 0 then break end
        end
        local count = addon_aborts('current')
        assert(control > 0, 'control: v1.2\'s step did not abort, so this test proves nothing')
        assert(count == 0, count .. ' "return to lower frame" aborts started in src/addon.lua (v1.2: ' .. control .. ')')
        print('PASS: the guarded step starts no trace that aborts on its return (v1.2: ' .. control .. ' aborts)')
    else
        print('SKIP: trace aborts (no JIT)')
    end
end

local pair = {reference = install('reference'), current = install('current')}
local frame, seen = 0, {calls = 0, lines = 0}
local function both(fn) fn(pair.reference); fn(pair.current) end
local function compare(label)
    local a, b = pair.reference, pair.current
    assert(#a.world.calls == #b.world.calls, label .. ': native calls ' .. #a.world.calls .. ' vs ' .. #b.world.calls)
    for i = seen.calls + 1, #a.world.calls do
        assert(serial(a.world.calls[i]) == serial(b.world.calls[i]), label .. ': call ' .. i .. ' '
            .. serial(a.world.calls[i]) .. ' vs ' .. serial(b.world.calls[i]))
    end
    assert(#a.lines == #b.lines, label .. ': log lines ' .. #a.lines .. ' vs ' .. #b.lines .. ': '
        .. tostring(a.lines[#a.lines]) .. ' / ' .. tostring(b.lines[#b.lines]))
    for i = seen.lines + 1, #a.lines do assert(a.lines[i] == b.lines[i], label .. ': ' .. a.lines[i] .. b.lines[i]) end
    seen.calls, seen.lines = #a.world.calls, #a.lines
    assert(status(a) == status(b), label .. ': status ' .. status(a) .. ' vs ' .. status(b))
end
local function compare_memory(label)
    local a, b = pair.reference.world, pair.current.world
    same_table(a.bytes, b.bytes, label .. ' memory')
    same_table(a.texts, b.texts, label .. ' texts')
    same_table(a.labels, b.labels, label .. ' labels')
end
-- n frames on both: the mod's update, then the escape menu's game update.
local function frames(n, label)
    for _ = 1, n do
        frame = frame + 1
        local results = {}
        both(function(t)
            t.world.sync()
            results[#results + 1] = serial({pcall(t.env.update, 0.016)})
            if t.world.menu_update then t.world.menu_update() end
        end)
        assert(results[1] == results[2], label .. ' frame ' .. frame .. ': update returned ' .. results[1] .. ' vs '
            .. results[2])
        compare(label .. ' frame ' .. frame)
        if frame % 50 == 0 then compare_memory(label .. ' frame ' .. frame) end
    end
end
local function squad(peers)
    both(function(t)
        local world = t.world
        world.session = {world.local_peer}
        for _, peer in ipairs(peers) do world.session[#world.session + 1] = peer end
        world.host = world.local_peer
        world.sync()
    end)
end
local function each(name, ...)
    local args = {...}
    both(function(t) t.world[name](unpack(args)) end)
end
local function results_of(fn)
    local out = {}
    both(function(t) out[#out + 1] = serial({fn(t)}) end)
    assert(out[1] == out[2], 'entry point returned ' .. out[1] .. ' vs ' .. out[2])
end

-- Idle on the ship, alone (the scanner's first write in the first frame).
frames(300, 'alone on the ship')
-- The game rewrites the scanner's field: the scanner writes its value again.
both(function(t) t.world.put32(Fake.SCANNER_CONFIG + S.RECHARGE, 20) end)
frames(50, 'scanner field rewritten')
-- No session, then a new one.
both(function(t) t.world.put64(Fake.GAME + G.CONTEXT_PTR, 0) end)
frames(50, 'no session')
both(function(t) t.world.put64(Fake.GAME + G.CONTEXT_PTR, Fake.CTX) end)
frames(50, 'new session')
-- A client of another host, with the escape menu open and closed.
both(function(t) t.world.session, t.world.host = {TANGO, t.world.local_peer}, TANGO; t.world.sync() end)
frames(60, 'client')
each('open_menu')
frames(30, 'client, menu open')
each('close_menu')
frames(60, 'client, menu closed')
-- Hosting a squad: the menu closed, then open with the player menu picking Charlie, then closed by the host.
squad({TANGO, CHARLIE})
frames(100, 'hosting, menu closed')
each('open_menu')
frames(30, 'hosting, menu open')
each('open_popup', 2, CHARLIE)
frames(5, 'player menu open')
each('open_popup', 2, nil)
frames(5, 'player menu closed')
each('close_menu')
frames(60, 'hosting, menu closed again')
-- Disband from the dialog (one cancelled answer first); everyone kicked, the menu stays open, then closed.
each('open_menu')
frames(10, 'disband: menu open')
each('focus', 4 + 2)
frames(2, 'disband: focus')
each('select'); frames(1, 'disband: select')
each('answer', false); frames(2, 'disband: cancelled')
each('hide_dialog'); frames(2, 'disband: hidden')
each('select'); frames(1, 'disband: select again')
each('answer', true); frames(40, 'disband: confirmed')
assert(pair.current.world.count('game_popup_kick') == 2 and #pair.current.world.session == 1, 'disbanded')
frames(30, 'alone, menu open after the disband')
each('close_menu')
frames(150, 'alone after the disband, menu closed')
-- A squad forms while the menu is closed (a hosting frame forgets the screen, as v1.2 did), then promote.
squad({TANGO})
frames(30, 'a new squad, menu closed')
both(function(t) t.world.successor = TANGO end)
each('open_menu')
frames(20, 'promote: menu open')
each('focus', 4 + 3)
frames(2, 'promote: focus')
each('select'); frames(1, 'promote: select')
each('answer', true); frames(120, 'promote: confirmed')
assert(pair.current.world.count('escape_closed') == 1, 'promote closed the escape menu')
both(function(t) t.world.arrivals = {TANGO, t.world.local_peer} end)
for _ = 1, math.ceil((L.FIRST_SEARCH + 2 + L.ARRIVAL_CHECK) / 0.016) do
    each('tick')
    frames(1, 'promote: the move and the arrival check')
end
-- The squad now lives in Tango's session: the rest starts from fresh games
-- (shut down and compared first), on the host's own ship.
compare_memory('after the promote')
both(function(t) t.env.shutdown() end)
compare('promote shutdown')
pair, seen = {reference = install('reference'), current = install('current')}, {calls = 0, lines = 0}
frames(30, 'fresh start')
-- Lua entry points with the menu closed, and the settings from Mod Options Menu.
squad({TANGO, CHARLIE})
frames(40, 'hosting again')
results_of(function(t) return t.state.promote({lo = CHARLIE.lo, hi = CHARLIE.hi}) end)
frames(20, 'promote from Lua, menu closed')
results_of(function(t) return t.state.cancel() end)
frames(40, 'promote cancelled')
both(function(t) t.env.ModOptionsMenu.callbacks['better_lobby_management.region'](2) end)
frames(200, 'own continent only') -- region checks every R.VERIFY_FRAMES frames
-- A config download replaces the table on idle frames: the next check writes it again.
both(function(t) t.world.download(0x0badc0de, {{'NA', 'EU', 1}}) end)
frames(200, 'own continent only, a new config download')
assert(pair.current.world.excluded('NA') == 'AF AN AS EU OC SA', pair.current.world.excluded('NA'))
both(function(t) t.env.ModOptionsMenu.callbacks['better_lobby_management.scanner_seconds'](3) end)
frames(30, 'scanner setting changed')
both(function(t) t.env.ModOptionsMenu.callbacks['better_lobby_management.messages'](2) end)
results_of(function(t) return t.state.disband() end)
frames(60, 'disband from Lua, messages off')
-- Alone in a mission: an SOS, CANCEL SOS from the escape menu, kept off, a new beacon.
squad({})
both(function(t) t.world.mode = G.MODE_MISSION; t.world.native_types = {2, 3}; t.world.sync() end)
frames(100, 'alone in a mission')
each('sos_beacon')
frames(100, 'alone in a mission, SOS on')
each('open_menu')
frames(20, 'SOS on, menu open')
each('focus', 4 + 2)
frames(2, 'cancel SOS: focus')
each('select'); frames(1, 'cancel SOS: select')
each('answer', true); frames(3, 'cancel SOS: confirmed')
assert(pair.current.world.count('sos_deactivate') == 1, 'SOS cancelled')
each('hide_dialog')
each('close_menu')
frames(200, 'SOS kept off, menu closed')
each('sos_beacon')
frames(100, 'a new SOS beacon')
-- A squad in the mission (joined while the menu is closed), a player leaving.
squad({TANGO, CHARLIE})
frames(60, 'hosting in a mission')
each('player_leaves', CHARLIE)
frames(60, 'a player left')
-- An error below: the mod pauses (60 clean frames) and resumes.
both(function(t) t.below.fail = true end)
frames(1, 'error below')
both(function(t) t.below.fail = false end)
frames(150, 'paused, then resumed')
-- Back to the ship, alone.
squad({})
both(function(t) t.world.mode = G.MODE_SHIP; t.world.sync() end)
frames(400, 'back on the ship')
compare_memory('end')
both(function(t) t.env.shutdown() end)
compare('shutdown')
assert(frame >= 2000, 'at least 2,000 frames: ' .. frame)
print('PASS: the idle gate and v1.2 make the same native calls, writes, log lines and status over ' .. frame
    .. ' frames (ship, mission, no session, client, host, promote, disband, CANCEL SOS, Lua entry points, settings, '
    .. 'an error below, shutdown)')

-- Idle frames allocate nothing (after a warm-up), alone on the ship and in a
-- mission, and while hosting a squad with the menu closed. Measured
-- interpreted, as the paused frames in test_addon.lua: a trace recorded inside
-- the window would count as heap growth too. v1.2's figures are printed.
local H = dofile(tests .. 'hostile_vm.lua')
local function idle_kb(which)
    local t = install(which)
    local out = {}
    local function measure(label)
        for _ = 1, 120 do t.env.update(0.016) end
        jit.off()
        out[#out + 1] = {label, H.heap_peak(function() for _ = 1, 1000 do t.env.update(0.016) end end)}
        jit.on()
    end
    measure('alone on the ship')
    t.world.mode = G.MODE_MISSION; t.world.sync()
    measure('alone in a mission')
    t.world.session = {t.world.local_peer, TANGO}; t.world.host = t.world.local_peer; t.world.sync()
    measure('hosting a squad in a mission, menu closed')
    t.world.mode = G.MODE_SHIP; t.world.sync()
    measure('hosting a squad on the ship, menu closed')
    return out
end
do
    local old, new = idle_kb('reference'), idle_kb('current')
    local text = {}
    for i, row in ipairs(new) do
        assert(row[2] == 0, row[1] .. ': ' .. row[2] .. ' KB over 1000 idle frames')
        text[#text + 1] = string.format('%s %.3f -> 0 KB', row[1], old[i][2])
    end
    print('PASS: idle frames allocate nothing (1000 frames each; v1.2 -> now: ' .. table.concat(text, '; ') .. ')')
end

-- The one intended difference. After a disband the host is alone with the
-- escape menu open and closes it: v1.2 kept that screen's state (nothing reads
-- the screen while alone on the ship); the idle gate forgets it, as v1.2 did
-- when a host closed the menu. A player then joins while the menu is open
-- again: both give DISBAND SQUAD and PROMOTE, and the confirm dialog is set up
-- with the same title, body and choices.
do
    local M_DIALOG_TITLE, M_DIALOG_BODY = MENU.current.DIALOG_TITLE, MENU.current.DIALOG_BODY
    local function edge(which)
        local t = install(which)
        local world = t.world
        local function run(n) for _ = 1, n do world.sync(); t.env.update(0.016); world.menu_update() end end
        world.session, world.host = {world.local_peer, TANGO}, world.local_peer
        world.sync()
        run(2)
        world.open_menu()
        run(2)
        world.focus(4 + 2)
        run(2)
        world.select(); run(1)
        world.answer(true); run(40)
        assert(#world.session == 1, which .. ': disbanded')
        world.hide_dialog()
        run(5)
        world.close_menu()
        run(30)
        world.open_menu()
        run(5)
        world.session = {world.local_peer, CHARLIE}
        world.sync()
        world.game_rebuild(world.native_types) -- the game rebuilds its list when a player joins
        run(3)
        local buttons = world.our_buttons()
        local setups = world.count('dialog_setup')
        world.focus(4 + 2)
        run(2)
        return {buttons = buttons, title = world.texts[world.dialog + M_DIALOG_TITLE],
                body = world.texts[world.dialog + M_DIALOG_BODY], setups = world.count('dialog_setup') - setups,
                calls = world.calls, queries = world.api.queries}
    end

    local old, new = edge('reference'), edge('current')
    assert(new.buttons == 'disband=DISBAND SQUAD promote=PROMOTE CHARLIE', new.buttons)
    assert(old.buttons == new.buttons, old.buttons .. ' vs ' .. new.buttons)
    assert(new.title == 'DISBAND SQUAD' and old.title == new.title, tostring(old.title) .. ' vs ' .. tostring(new.title))
    assert(new.body == ENGLISH.strings['dialog.disband.body'] and old.body == new.body, tostring(new.body))
    assert(new.setups == 1, 'the dialog is set up with the game\'s confirm and cancel choices: ' .. new.setups)
    -- What v1.2 and now call in all (the game's natives) and how many page checks
    -- (writable_data, a VirtualQuery in game) they make, by name.
    local function by_name(calls)
        local out = {}
        for _, call in ipairs(calls) do out[call.name] = (out[call.name] or 0) + 1 end
        return out
    end
    local a, b, names, diff = by_name(old.calls), by_name(new.calls), {}, {}
    for name in pairs(a) do names[name] = true end
    for name in pairs(b) do names[name] = true end
    for name in pairs(names) do
        if a[name] ~= b[name] then diff[#diff + 1] = name .. ' ' .. (a[name] or 0) .. ' -> ' .. (b[name] or 0) end
    end
    table.sort(diff)
    print(string.format('PASS: a closed escape screen is forgotten whoever closed it: after a disband, closing the menu '
        .. 'alone and a player joining with it open, the buttons and the dialog (%s) match v1.2; native calls v1.2 -> '
        .. 'now: %s; page checks %d -> %d', new.title, #diff > 0 and table.concat(diff, ', ') or 'the same',
        old.queries, new.queries))
end


-- A menu system that cannot be confirmed (its screen field unreadable): the
-- full frame runs, as in v1.2, and the gate tries the guarded read again on
-- every 60th frame only; once readable, idle frames are 4 direct loads.
do
    local budget = dofile(tests .. 'frame_budget.lua')
    local t = install('current')
    local world = t.world
    world.unmapped[Fake.MENU + MENU.current.SCREEN] = true
    t.env.update(0.016) -- the first frame: the full one, the scanner's first write
    local counts = budget.wrap(world.api)
    local reads, full = 0, 0
    for _ = 1, 120 do
        local f = budget.frame(counts, t.env.update, 0.016)
        reads = reads + (f.read64 or 0)
        if (f.load32 or 0) > 1 then full = full + 1 end
    end
    assert(reads == 2 and full == 120, 'unconfirmed: ' .. reads .. ' guarded reads, ' .. full .. ' full frames')
    world.unmapped[Fake.MENU + MENU.current.SCREEN] = nil
    for _ = 1, 60 do t.env.update(0.016) end
    local f = budget.frame(counts, t.env.update, 0.016)
    assert(budget.describe(f) == 'load32=1 load64=3', budget.describe(f))
    print('PASS: a menu system that cannot be confirmed leaves the full frame running (as v1.2) and is tried again '
        .. 'every 60th frame (2 guarded reads in 120 frames); once readable, idle frames are 4 direct loads')
end
