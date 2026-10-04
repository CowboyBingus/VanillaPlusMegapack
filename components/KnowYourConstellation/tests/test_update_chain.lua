-- The update chain: the real installer on the vendored runtime guard
-- (src/bingus_runtime.lua), over fake readers and panel:
-- - the previous update runs outside pcall: its error object reaches the
--   caller unchanged, and every argument and return value passes through;
-- - the mod's own errors count in bursts: 8 errors not separated by 3600
--   error-free frames stop it for the session, each burst logs one line;
-- - after an update below raised, the mod removes its panel and pauses; it
--   resumes on the frame after the updates below have returned on 60 frames
--   in a row; 8 such failures in one burst stop it;
-- - the first failure survives shutdown; a session without one keeps its status;
-- - an expected transient state (a raised {pending = reason} table) hides the
--   forecast and retries as v4.0 did, and never counts toward a stop;
-- - the game build is checked through the shared runtime's read side, whose
--   module hashes every mod on the runtime shares.
local source = assert(arg[1])
local install = assert(loadfile(source .. '/install.lua'))()
local runtime = assert(loadfile(source .. '/bingus_runtime.lua'))()
local model = assert(loadfile(source .. '/model.lua'))()
local roster = assert(loadfile(source .. '/roster.lua'))()
local roster_data = assert(loadfile(source .. '/roster_data.lua'))()
local text = assert(loadfile(source .. '/bingus_text.lua'))()
local english = assert(loadfile(source .. '/../locales/en.lua'))()
local NAME = 'KnowYourConstellation'

-- One installed mod. w.raise makes its frame raise; w.lower makes the previous
-- update raise; w.clear_raises makes removing the panel raise. options.verify
-- is what the build check answers (default: supported).
local WAIT = {pending = 'Mission descriptor not ready', status = 'hidden: Mission descriptor not ready'}
local function world(options)
    options = options or {}
    local w = {clears = 0, shows = 0, printed = 0, previous_calls = 0, log = '', checks = {}}
    local reader = {}
    function reader:screen()
        if w.raise then error(w.raise, 0) end
        return 'map'
    end
    function reader:descriptor() return {key = 'mission', screen = 'map', controller_matches = true} end
    function reader:sample()
        return {key = 'mission', screen = 'map', tags = {1}, difficulty = 10, faction = 2, complete = true,
            controller_matches = true}
    end
    local surface = {}
    function surface:show() w.shows = w.shows + 1 return true end
    function surface:suspend() end
    function surface:clear()
        w.clears = w.clears + 1
        if w.clear_raises then error('the panel could not be removed', 0) end
    end
    local env = setmetatable({stingray = {Gui = {}, World = {}}, os = {}, io = io}, {__index = _G})
    env._G = env
    env.print = function() w.printed = w.printed + 1 end
    env.CowboyBingusModLoader = {open_log = function()
        local parts = {}
        return {write = function(_, value) parts[#parts + 1] = value end,
                close = function() w.log = table.concat(parts) end}
    end}
    if not options.alone then
        env.update = function(dt, marker)
            w.previous_calls = w.previous_calls + 1
            if w.lower then error(w.lower, 0) end
            return 'game', dt, marker
        end
    end
    env.shutdown = function() w.shutdowns = (w.shutdowns or 0) + 1 return 'shut' end
    local api = options.api or function() return {module = function() return 1 end} end
    local memory = {new = function(core)
        assert(core == runtime, 'the read side gets the runtime core')
        return {verify_build = function(build)
            w.checks[#w.checks + 1] = build
            if options.verify == nil then return true end
            return options.verify, options.why
        end}
    end}
    setfenv(install, env)({create_api = api, mission = {new = function() return reader end}, resolve = {},
        roster = roster, roster_data = roster_data, model = model, panel = {new = function() return surface end},
        presentation = {new = function() return {sample = function() return {client = false, active = true, font = 'f'} end} end},
        text = text, locales = {en = english, bundled = {}}, runtime = runtime, runtime_memory = memory,
        build = {revision = 'chain', game_sha256 = 'game-hash', exe_sha256 = 'exe-hash'}})
    w.env, w.state = env, env.EnemyIntelligence
    w.guard = w.state.guard
    return w
end
-- Log lines below the status line that start with `prefix`.
local function lines(w, prefix)
    local n, index = 0, 0
    for line in w.log:gmatch('[^\n]+') do
        index = index + 1
        if index > 2 and line:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
end
local function frames(w, n, dt)
    for _ = 1, n do w.env.update(dt or 0.016) end
end

-- The guard is the runtime's, under the mod's name, its status shared in
-- BingusRuntime; the build check went through the runtime's read side once.
local w = world()
assert(w.env.BingusRuntime.statuses[NAME] == w.guard and w.guard.installed and w.guard.state == 'running')
local a, b, c = w.env.update(0.25, 'marker')
assert(a == 'game' and b == 0.25 and c == 'marker', 'every argument and return value passes through')
assert(w.shows == 1 and w.state.status:find('^visible'), 'the forecast shows')
assert(#w.checks == 1 and w.checks[1].exe_sha256 == 'exe-hash' and w.checks[1].game_sha256 == 'game-hash',
    'the build is checked once, through the shared runtime')
frames(w, 5)
assert(#w.checks == 1)

-- Pass-through and the previous update outside pcall.
local thrown = {}
w.lower = thrown
local ok, err = pcall(w.env.update, 0.016)
assert(not ok and err == thrown, 'the previous update raises its own error object, uncaught')
local frames_before = w.state.frames
w.lower = nil

-- A failed update below pauses: the panel goes, no frame runs, one log line;
-- the frame after 60 frames in a row in which the updates below return resumes it.
local clears, printed = w.clears, w.printed
frames(w, 1)
assert(w.state.status == 'paused: the previous update failed' and w.guard.pauses == 1 and w.guard.lower_errors == 1)
assert(w.clears == clears + 1 and w.state.frames == frames_before, 'a pause removes the panel and runs no frame')
assert(lines(w, NAME .. ' paused: ') == 1 and w.printed == printed + 1)
frames(w, 59)
assert(w.state.frames == frames_before, 'paused while the updates below return on 60 frames')
frames(w, 1)
assert(w.state.frames == frames_before + 1 and w.state.status:find('^visible'), 'the next frame resumes it')
assert(lines(w, NAME .. ' resumed after 60 clean frames') == 1)
-- More failures below while paused add no line; the pause lasts 60 clean frames.
for _ = 1, 3 do
    w.lower = thrown
    pcall(w.env.update, 0.016)
    w.lower = nil
end
frames(w, 1)
assert(w.guard.pauses == 2 and w.guard.lower_errors == 4 and lines(w, NAME .. ' paused: ') == 2)
frames_before = w.state.frames
frames(w, 59)
assert(w.state.frames == frames_before)
frames(w, 1)
assert(w.state.frames == frames_before + 1)
-- 3600 frames with every update below returning end the burst.
frames(w, 3600)
assert(w.guard.lower_errors == 0)
-- The guard resumes at the start of the frame after the 60th clean update
-- below. An update below that fails on that very frame pauses it again on the
-- next one (the old hand-written chain resumed only after it returned).
w = world()
frames(w, 1)
w.lower = thrown
pcall(w.env.update, 0.016)
w.lower = nil
frames(w, 60)
assert(w.guard.pauses == 1 and lines(w, NAME .. ' resumed after 60 clean frames') == 0)
w.lower = thrown
assert(not pcall(w.env.update, 0.016))
w.lower = nil
assert(lines(w, NAME .. ' resumed after 60 clean frames') == 1, 'resumed before the update below ran')
frames(w, 1)
assert(w.guard.pauses == 2 and w.state.status == 'paused: the previous update failed'
    and lines(w, NAME .. ' paused: ') == 2, 'paused again on the next frame')

-- 8 failed updates below in one burst stop the mod for the session.
w = world()
frames(w, 1)
for i = 1, 8 do
    w.lower = thrown
    assert(not pcall(w.env.update, 0.016))
    w.lower = nil
    w.env.update(0.016)
    if i < 8 then assert(w.state.status:find('^paused')) end
end
assert(w.state.status == 'stopped after: 8 failed updates below this mod'
    and w.guard.state == 'stopped: stopped after 8 failed updates below this mod')
local calls = w.previous_calls
frames_before = w.state.frames
frames(w, 100)
assert(w.state.frames == frames_before and w.previous_calls == calls + 100, 'a stopped mod only passes the frame on')
assert(w.env.shutdown() == 'shut' and w.shutdowns == 1)
assert(w.state.status == 'stopped after: 8 failed updates below this mod', 'the first failure survives shutdown')
assert(w.guard.state == 'stopped after: stopped after 8 failed updates below this mod')

-- The mod's own errors: one log line per burst; the 8th error of a burst stops it.
w = world()
frames(w, 1)
printed = w.printed
w.raise = 'reader failed'
frames(w, 7)
assert(w.guard.errors == 7 and w.state.failures == 7 and w.state.status == 'hidden: reader failed')
assert(lines(w, NAME .. ' error: ') == 1 and w.printed == printed + 1, 'one log line for the burst')
frames(w, 1)
assert(w.state.status == 'stopped after: 8 errors: reader failed')
assert(w.printed == printed + 2 and lines(w, NAME .. ' error: ') == 1 and lines(w, NAME .. ' stopped: ') == 1)
frames_before = w.state.frames
frames(w, 50)
assert(w.state.frames == frames_before, 'no frame runs after the stop')
w.env.shutdown()
assert(w.state.status == 'stopped after: 8 errors: reader failed')

-- Bursts separated by 3600 error-free frames never add up; one line each.
w = world()
for burst = 1, 3 do
    w.raise = 'transient ' .. burst
    frames(w, 7)
    w.raise = nil
    frames(w, 3600)
    assert(w.guard.errors == 0 and lines(w, NAME .. ' error: ') == burst)
end
assert(w.state.failures == 21 and w.state.status:find('^visible'), 'three bursts of 7 never stop the mod')
-- 3599 error-free frames do not end a burst: its 8th error stops the mod.
w.raise = 'late'
frames(w, 7)
w.raise = nil
frames(w, 3599)
w.raise = 'late again'
frames(w, 1)
assert(w.state.status == 'stopped after: 8 errors: late')

-- A pause that cannot remove the panel stops the mod.
w = world()
frames(w, 1)
w.lower, w.clear_raises = thrown, true
pcall(w.env.update, 0.016)
w.lower = nil
frames(w, 1)
assert(w.state.status == 'stopped after: pause failed: the panel could not be removed')

-- An update below that raised on the last frame is the first failure at shutdown.
w = world()
frames(w, 3)
w.lower = thrown
pcall(w.env.update, 0.016)
w.env.shutdown()
assert(w.state.status == 'stopped after: the previous update failed')
-- A session without a failure keeps its last status through shutdown.
w = world()
frames(w, 3)
local last = w.state.status
w.env.shutdown()
assert(w.state.status == last and last:find('^visible'))
-- A refused start (unsupported game) is the first failure, and nothing runs again.
local starts = 0
w = world({api = function() starts = starts + 1 error('Unsupported game module', 0) end})
frames(w, 5)
assert(starts == 1 and w.state.status == 'stopped after: disabled: Unsupported game module')
assert(w.guard.first_failure == 'disabled: Unsupported game module')
w.env.shutdown()
assert(w.state.status == 'stopped after: disabled: Unsupported game module')
-- The build check refuses an unsupported game before any reader exists.
starts = 0
w = world({verify = false, why = 'unsupported game build',
    api = function() starts = starts + 1 return {module = function() return 1 end} end})
frames(w, 5)
assert(starts == 0 and #w.checks == 1 and w.state.status == 'stopped after: disabled: unsupported game build')
-- Without a game update to wrap the guard cannot install: the mod refuses at once.
w = world({alone = true})
assert(w.env.update == nil and w.state.status == 'stopped after: disabled: game update unavailable')
assert(not w.guard.installed and w.guard.first_failure == 'disabled: game update unavailable')

-- An expected transient state never counts: 10,000 waiting frames hide the
-- forecast with the reason (one status line, no error line) and it is back once
-- the state clears.
w = world()
frames(w, 1)
printed = w.printed
w.raise = WAIT
frames(w, 10000)
assert(w.state.status == 'hidden: Mission descriptor not ready' and w.state.pending == 10000)
assert(w.guard.errors == 0 and w.state.failures == 0 and not w.guard.first_failure and lines(w, NAME .. ' error: ') == 0)
assert(w.printed == printed + 1 and w.shows == 1, 'one status line; nothing drawn while waiting')
w.raise = nil
frames(w, 1)
assert(w.state.status:find('^visible') and w.shows == 2, 'the forecast is back once the state clears')
-- Genuine errors still stop the mod: waiting frames between them neither count
-- nor end the burst before 3600 frames.
w.raise = 'reader failed'
frames(w, 7)
w.raise = WAIT
frames(w, 100)
w.raise = 'reader failed'
frames(w, 1)
assert(w.state.status == 'stopped after: 8 errors: reader failed')
-- 3600 waiting frames end a burst like 3600 error-free frames.
w = world()
w.raise = 'transient'
frames(w, 7)
w.raise = WAIT
frames(w, 3600)
assert(w.guard.errors == 0 and w.state.pending == 3600)
w.raise = 'transient'
frames(w, 7)
assert(w.guard.errors == 7 and w.state.status == 'hidden: transient', 'a new burst, not a stop')
print('PASS: update chain on the runtime guard: previous update uncaught, pause and resume after a failed update '
      .. 'below, bursts of 8 errors stop, one log line per burst, first failure kept through shutdown, expected '
      .. 'transient states never counted, the build checked once through the shared runtime')
