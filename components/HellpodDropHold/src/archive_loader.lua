-- The mod's lifecycle on bingus_runtime.lua's update guard (the family's
-- update-chain policy):
-- - the earlier update runs outside pcall, so its errors reach the game unchanged;
-- - after the earlier update has returned, the hold runs its frame: a poll every
--   0.25 s while no loading screen is up, every frame while one is;
-- - a refusal (a layout or setting the hold cannot verify) stops the mod at once;
--   its own errors stop it after 8 in a burst;
-- - after an error in an update below this mod, the mod releases a held pod and
--   starts afresh once the updates below have returned on 60 frames in a row;
--   8 such errors in a burst stop it, with the pod released. When the mod stops
--   it releases the pod too; the game quitting writes nothing.
-- The log keeps the status and the last events (loading screens, holds, releases).
return function(create_api, hold, build, runtime)
    if _G.HellpodDropHold then return end
    local state = {revision = build.revision, active = false, status = '', events = {}}
    _G.HellpodDropHold = state  -- lint-ok: R8 the mod's one status table, named after the mod like every family mod's
    local clock = 0
    local function flush()
        pcall(function()
            local logger = rawget(_G, 'CowboyBingusModLoader')
            local file = logger and logger.open_log and logger.open_log('HellpodDropHold.log')
            if not file then return end
            file:write(build.revision .. '\n' .. state.status .. '\n')
            for _, line in ipairs(state.events) do file:write(line .. '\n') end
            file:close()
        end)
    end
    local function report(status, active)
        state.active = active
        if state.status == status then return end
        state.status = status
        print('[HellpodDropHold] ' .. build.revision .. ': ' .. status)
        flush()
    end
    -- Events are rare (a few per mission load); the file keeps the last 40.
    local function note(text)
        local events = state.events
        events[#events + 1] = string.format('%9.2f s  %s', clock, text)
        if #events > 40 then table.remove(events, 1) end
        print('[HellpodDropHold] ' .. text)
        flush()
    end
    -- Both game modules must be the supported build (SHA-256, read once per session for
    -- every mod); any other build gets no change at all.
    local function start()
        if type(runtime) ~= 'table' or type(runtime.guard) ~= 'function' then
            return nil, 'bingus_runtime.lua v1 is required'
        end
        local api = create_api()
        local supported, why = api.verify_build({exe_sha256 = build.exe_sha256, game_sha256 = build.game_sha256})
        if not supported then return nil, why .. '; no change applied' end
        if type(update) ~= 'function' then return nil, 'game update unavailable; no change applied' end
        return api, api.address(api.module('game.dll'))
    end
    local started, api, game = pcall(start)
    if not started or not api then report(tostring(started and game or api), false); return end
    local session, guard
    local function fresh()
        session = hold.session(build.test_hold_seconds)
        session.note = note
    end
    fresh()
    report(build.test_hold_seconds and ('test build: every own drop pod is held for '
        .. build.test_hold_seconds .. ' s') or 'waiting_for_loading_screen', true)
    local frame_dt = 0
    local function step(dt) frame_dt = dt end
    local function frame()
        if type(frame_dt) == 'number' and frame_dt > 0 and frame_dt < 10 then clock = clock + frame_dt end
        local running, reason = hold.update(api, game, session, frame_dt)
        if running == false then guard.stop(reason) end
    end
    -- Releases a held pod; a failed write raises.
    local function release(reason)
        local released, problem = hold.release(api, game, session, reason)
        if not released then error(problem, 0) end
    end
    -- After an error below: release, then start afresh (the next frame polls at once).
    local function pause()
        release('paused')
        fresh()
    end
    -- At shutdown nothing is written: the game is freeing its memory.
    local function stop(reason)
        if reason ~= 'shutdown' then release('stopped') end
    end
    local prefix = 'HellpodDropHold '
    local function log(line)
        if line:sub(1, #prefix) == prefix then line = line:sub(#prefix + 1) end
        report(line, false)
    end
    local installed, problem = pcall(function()
        guard = runtime.guard({name = 'HellpodDropHold', step = step, after = frame, stop = stop,
            pause = pause, log = log, env = _G}).install()
    end)
    if not installed then report(tostring(problem), false) end
end
