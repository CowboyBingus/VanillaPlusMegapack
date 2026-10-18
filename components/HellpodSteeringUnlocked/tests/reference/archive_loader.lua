-- The mod's lifecycle on bingus_runtime.lua's update guard (the family's
-- update-chain policy):
-- - the earlier update runs outside pcall, so its errors reach the game unchanged;
-- - every 100 ms, after the earlier update has returned, the patch checks the
--   avoidance flag and clears it over the game's own value;
-- - a refusal (a layout the patch cannot verify) stops the mod at once; its own
--   errors stop it after 8 in a burst;
-- - after an error in an update below this mod, the mod puts the game's value
--   back over its own write and starts afresh: once the updates below have
--   returned on 60 frames in a row it checks again. 8 such errors in a burst
--   stop it, with the game's value put back. The game quitting writes nothing.
return function(create_api, patch, build, runtime)
    if _G.HellpodSteeringUnlocked then return end
    local state = {revision = build.revision, active = false, status = ''}
    _G.HellpodSteeringUnlocked = state
    local function report(status, active)
        state.active = active
        if state.status == status then return end
        state.status = status
        print('[HellpodSteeringUnlocked] ' .. build.revision .. ': ' .. status)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('HellpodSteeringUnlocked.log')
            if file then file:write(build.revision .. '\n' .. status .. '\n'); file:close() end
        end)
    end
    local ok, api, game = pcall(function()
        assert(type(runtime) == 'table' and type(runtime.guard) == 'function', 'bingus_runtime.lua v1 is required')
        local api = create_api()
        local exe, game = api.module(nil), api.module('game.dll')
        assert(exe and game, 'Required game modules unavailable')
        assert(api.module_hash(exe) == build.exe_sha256, 'Unsupported executable; no change applied')
        assert(api.module_hash(game) == build.game_sha256, 'Unsupported game module; no change applied')
        assert(type(update) == 'function', 'Game update unavailable; no change applied')
        return api, game
    end)
    if not ok then report(tostring(api), false); return end
    report('waiting_for_mission', false)
    local POLL, own, guard = 0.1, {}, nil
    local elapsed, frame_dt = POLL, 0
    local function step(dt) frame_dt = dt end
    -- Because mission initialization resets the flag, it is checked every 100 ms.
    local function poll()
        local dt = frame_dt
        elapsed = elapsed + ((type(dt) == 'number' and dt == dt and dt > 0) and dt or 0)
        if elapsed < POLL then return end
        elapsed = 0
        local accepted, reason, active = patch.apply(api, game, own)
        if not accepted then return guard.stop(reason) end
        report(tostring(reason), active == true)
    end
    -- Puts the game's value back over this mod's own write; a failed write raises.
    local function restore()
        local restored, outcome = patch.restore(api, game, own)
        if outcome ~= 'nothing_to_restore' then report(state.status .. '; ' .. outcome, false) end
        if not restored then error(outcome, 0) end
    end
    -- The first frame after the resume checks at once.
    local function pause()
        elapsed = POLL
        restore()
    end
    -- At shutdown nothing is written: the game is freeing its memory and the
    -- flag no longer matters.
    local function stop(reason)
        if reason ~= 'shutdown' then restore() end
    end
    local prefix = 'HellpodSteeringUnlocked '
    local function log(line)
        if line:sub(1, #prefix) == prefix then line = line:sub(#prefix + 1) end
        report(line, false)
    end
    local installed, problem = pcall(function()
        guard = runtime.guard({name = 'HellpodSteeringUnlocked', step = step, after = poll, stop = stop,
            pause = pause, log = log, env = _G}).install()
    end)
    if not installed then report(tostring(problem), false) end
end
