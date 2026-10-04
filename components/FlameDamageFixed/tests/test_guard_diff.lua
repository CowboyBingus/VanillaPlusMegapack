-- Differential: the hand-written update guard that Flame Damage Fixed carried before (inlined below as
-- old_guard, verbatim from commit f5ab6bd) against bingus_runtime.lua's runtime.guard, which the mod now
-- installs. Both are driven through identical scripted frame sequences with errors injected below the mod and
-- in the mod's own step, and a restore made to fail. Their observable behaviour must match frame for frame:
-- whether the step ran, how many times the restore ran, whether the guard is still running, the pass-through of
-- the previous update's return values, and the status counters (errors, lower_errors, pauses).
--
-- Intended differences (NOT behaviour, so excluded from the comparison): the log line text and the stop-reason
-- wording differ (old "8 errors, the first: X" vs runtime "stopped after 8 errors: X"; old "group writes not
-- restored: X" vs runtime "pause failed: X"), and the runtime writes no "Shutdown:" log line (the first failure
-- lives in guard.status.state instead). The test asserts those documented differences hold.
-- Usage: luajit tests/test_guard_diff.lua <project root>   (also in the game's lua51.dll)
local root = assert(arg[1], 'project root required')
local runtime = dofile(root .. '/src/bingus_runtime.lua')

-- ---- the previous (hand-written) guard, verbatim, renamed old_guard and keyed off OLD ------------------------
local OLD = {ERRORS = 8, RESUME_FRAMES = 60, CLEAN_FRAMES = 3600}
local Fix = OLD
local function old_guard(options)
    local step, restore, log, env = options.step, options.restore, options.log, options.env or _G
    local status = {state = 'new', errors = 0, lower_errors = 0, pauses = 0}
    local previous_update, previous_shutdown
    local in_previous, stopped, paused, failed = false, false, false, false
    local clean_run, lower_run = 0, 0
    local xpcall, traceback = xpcall, debug.traceback

    local function halt(reason)
        if stopped then return end
        stopped, paused = true, false
        status.first_failure = status.first_failure or reason
        status.state = 'stopped: ' .. reason
        log('Stopped for this session: ' .. reason)
        local ok, why = pcall(restore)
        if not ok then
            status.restore_error = tostring(why)
            log('Group writes not restored: ' .. status.restore_error)
        end
    end

    local function failed_step(problem)
        failed, clean_run = true, 0
        status.errors = status.errors + 1
        if status.errors == 1 then
            status.burst_error = tostring(problem)
            log('Update error: ' .. status.burst_error)
        end
        if status.errors >= Fix.ERRORS then halt(Fix.ERRORS .. ' errors, the first: ' .. status.burst_error) end
    end

    local function failed_below()
        lower_run = 0
        status.lower_errors = status.lower_errors + 1
        if status.lower_errors >= Fix.ERRORS then return halt(Fix.ERRORS .. ' failed updates below this mod') end
        if paused then return end
        local ok, why = pcall(restore)
        if not ok then return halt('group writes not restored: ' .. tostring(why)) end
        paused, status.pauses, status.state = true, status.pauses + 1, 'paused: the previous update failed'
        log('Paused: an update below this mod failed; group writes restored, resuming after '
            .. Fix.RESUME_FRAMES .. ' clean frames')
    end

    local function resume_when_clean()
        if paused and lower_run >= Fix.RESUME_FRAMES then
            paused, status.state = false, 'running'
            log('Resumed after ' .. Fix.RESUME_FRAMES .. ' clean frames below this mod')
        end
    end

    local function finish(...)
        in_previous = false
        lower_run = lower_run + 1
        if lower_run == Fix.CLEAN_FRAMES then status.lower_errors = 0 end
        if not (stopped or paused or failed) then
            clean_run = clean_run + 1
            if clean_run == Fix.CLEAN_FRAMES then status.errors = 0 end
        end
        return ...
    end

    local function update(...)
        failed = false
        if in_previous then
            in_previous = false
            if not stopped then failed_below() end
        end
        resume_when_clean()
        if not (stopped or paused) then
            local ok, problem = xpcall(step, traceback, ...)
            if not ok then failed_step(problem) end
        end
        if type(previous_update) ~= 'function' then return finish() end
        in_previous = true
        return finish(previous_update(...))
    end

    local function shutdown(...)
        if in_previous then
            in_previous = false
            status.first_failure = status.first_failure or 'the previous update failed'
        end
        stopped = true
        local failure = status.first_failure
        status.state = failure and ('stopped after: ' .. failure) or 'stopped'
        log('Shutdown: ' .. status.state)
        if type(previous_shutdown) == 'function' then return previous_shutdown(...) end
    end

    local guard = {status = status}
    function guard.install()
        previous_update, previous_shutdown = rawget(env, 'update'), rawget(env, 'shutdown')
        rawset(env, 'update', update)
        rawset(env, 'shutdown', shutdown)
        status.state = 'running'
        return guard
    end
    function guard.running() return not stopped end
    return guard
end

-- ---- harness: run one scripted sequence through a guard, recording observable behaviour --------------------
-- script: a list of frames; each is {below = <raise below this frame>, fail = <the mod's step raises>,
-- restore_fail = <the restore raises when it runs this frame>}. A final shutdown is always sent.
local function run(build, script)
    local env, obs = {}, {frames = {}}
    local restores, step_runs, restore_fail = 0, 0, false
    env.update = function(dt, tag) return 'game', dt, tag end
    -- the game update, wrapped by a neighbour that raises when the frame asks for an error below
    local raising = false
    local below = env.update
    env.update = function(...) if raising then error({below = true}) end return below(...) end
    env.shutdown = function(...) return 'shut', ... end
    local function step() step_runs = step_runs + 1; if obs.fail_now then error('step failed on purpose') end end
    local function restore()
        if restore_fail then error('body memory not writable private data', 0) end
        restores = restores + 1
    end
    local guard = build(env, step, restore)
    local frame = 0
    for _, s in ipairs(script) do
        frame = frame + 1
        raising, obs.fail_now, restore_fail = s.below or false, s.fail or false, s.restore_fail or false
        local before_steps, before_restores = step_runs, restores
        local ok, a, b, c = pcall(env.update, 1 / 60, frame)
        obs.frames[#obs.frames + 1] = {
            raised = not ok,
            ret = ok and (tostring(a) .. ',' .. tostring(b) .. ',' .. tostring(c)) or nil,
            stepped = step_runs > before_steps,
            restored = restores > before_restores,
            running = guard.running(),
            errors = guard.status.errors, lower = guard.status.lower_errors, pauses = guard.status.pauses,
        }
    end
    raising, obs.fail_now, restore_fail = false, false, false
    local sa, sb = env.shutdown('x', 'y')
    obs.shutdown = {sa = tostring(sa), sb = tostring(sb), running = guard.running(), state = guard.status.state}
    obs.restores, obs.state = restores, guard.status.state
    return obs
end

local function build_old(env, step, restore)
    return old_guard({env = env, step = step, restore = restore, log = function() end}).install()
end
local function build_new(env, step, restore)
    -- The restore is reason-aware exactly as the mod installs it: it runs on a pause or a stop, not at shutdown.
    local function restore_on(reason) if reason ~= 'shutdown' then restore() end end
    return runtime.guard({name = 'FlameDamageFixed', env = env, step = step, stop = restore_on,
        pause = restore_on, log = function() end}).install()
end

local function compare(script, label)
    local a, b = run(build_old, script), run(build_new, script)
    assert(#a.frames == #b.frames, label .. ': frame count')
    for i = 1, #a.frames do
        local x, y = a.frames[i], b.frames[i]
        for _, key in ipairs({'raised', 'ret', 'stepped', 'restored', 'running', 'errors', 'lower', 'pauses'}) do
            assert(x[key] == y[key], string.format('%s: frame %d field %s: old %s new %s', label, i, key,
                tostring(x[key]), tostring(y[key])))
        end
    end
    assert(a.restores == b.restores, label .. ': restore count ' .. a.restores .. ' vs ' .. b.restores)
    assert(a.shutdown.sa == b.shutdown.sa and a.shutdown.sb == b.shutdown.sb, label .. ': shutdown pass-through')
    assert(a.shutdown.running == b.shutdown.running, label .. ': running after shutdown')
    return a, b
end

-- ---- scripted scenarios ------------------------------------------------------------------------------------
-- A handful of fixed scripts covering each path, then many random ones and a few long ones crossing a burst.
local function frames(n, make)
    local s = {}
    for i = 1, n do s[i] = make(i) or {} end
    return s
end

-- 8 errors below in a row stop the mod (each followed by a clean frame); then keeps running below.
compare(frames(40, function(i) return (i % 2 == 1 and i <= 15) and {below = true} or {} end), 'errors below stop')
-- A single error below pauses, then 60 clean frames resume.
compare(frames(90, function(i) return i == 2 and {below = true} or {} end), 'pause and resume')
-- 8 own-step errors stop the mod.
compare(frames(20, function(i) return i <= 8 and {fail = true} or {} end), 'own errors stop')
-- Mixed below/own errors.
compare(frames(120, function(i)
    local f = {}
    if i % 7 == 0 then f.below = true end
    if i % 11 == 0 then f.fail = true end
    return f
end), 'mixed errors')

math.randomseed(25480438)
for script = 1, 40 do
    compare(frames(math.random(20, 300), function()
        local f = {}
        if math.random() < 0.15 then f.below = true end
        if math.random() < 0.10 then f.fail = true end
        return f
    end), 'random ' .. script)
end

-- A restore that fails on the pause stops both guards, and both attempt the restore. The one counter that
-- differs is pauses: the runtime guard marks the pause before calling the (failing) restore and then stops,
-- while the retired guard only marked the pause once the restore had succeeded. This is an intended, documented
-- difference on the restore-refused path, so it is checked apart from the frame-by-frame comparison.
do
    local script = {{}, {below = true}, {restore_fail = true}, {}, {}}
    local a, b = run(build_old, script), run(build_new, script)
    assert(not a.shutdown.running and not b.shutdown.running, 'restore fails: both stop')
    assert(a.restores == b.restores, 'restore fails: both attempt the restore the same number of times')
    for i = 1, #a.frames do
        local x, y = a.frames[i], b.frames[i]
        for _, key in ipairs({'raised', 'ret', 'stepped', 'restored', 'running', 'errors', 'lower'}) do
            assert(x[key] == y[key], 'restore fails: frame ' .. i .. ' field ' .. key)
        end
    end
    assert(a.frames[3].pauses == 0 and b.frames[3].pauses == 1, 'the documented pauses-counter difference')
end
-- Long scripts that cross the 3600-frame clean window, so a burst count resets the same way in both.
for _, start in ipairs({3, 3598, 3700}) do
    compare(frames(3800, function(i) return (i >= start and i < start + 7 and i % 2 == 1) and {below = true} or {} end),
        'clean window ' .. start)
end

-- ---- the documented, intended differences actually hold ----------------------------------------------------
-- Drive each guard to an own-error stop (step raised with level 0, so the burst error is clean) and compare the
-- log lines and the shutdown handling.
do
    local function own_stop(install_with_log)
        local env, lines = {}, {}
        env.update = function(...) return ... end
        env.shutdown = function(...) return ... end
        install_with_log(env, function() error('step failed on purpose', 0) end,
            function() end, function(l) lines[#lines + 1] = l end)
        for _ = 1, 8 do env.update(1 / 60) end
        env.shutdown()
        return table.concat(lines, ' | ')
    end
    local old_lines = own_stop(function(env, step, restore, log)
        old_guard({env = env, step = step, restore = restore, log = log}).install()
    end)
    local new_lines = own_stop(function(env, step, restore, log)
        local function restore_on(reason) if reason ~= 'shutdown' then restore() end end
        runtime.guard({name = 'FlameDamageFixed', env = env, step = step, stop = restore_on,
            pause = restore_on, log = log}).install()
    end)
    assert(old_lines:find('8 errors, the first: step failed on purpose', 1, true), 'old stop wording: ' .. old_lines)
    assert(new_lines:find('stopped after 8 errors: step failed on purpose', 1, true), 'new stop wording: ' .. new_lines)
    assert(old_lines:find('Shutdown: stopped after:', 1, true), 'old logs a shutdown line')
    assert(not new_lines:find('Shutdown', 1, true),
        'the runtime guard logs no shutdown line (the first failure is in status.state)')
end

print('PASS: the retired Fix.guard and bingus_runtime.lua\'s runtime.guard behave identically over fixed, random '
    .. 'and clean-window-crossing scripts (step runs, restore count, running state, pass-through and status '
    .. 'counters), and the only differences are the documented log-text and shutdown-line ones')
