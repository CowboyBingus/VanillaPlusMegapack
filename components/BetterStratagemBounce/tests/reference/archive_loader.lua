return function(create_api, patch, build)
    if _G.BetterStratagemBounce then return end
    local state = {revision = build.revision, active = false, status = 'pending'}
    _G.BetterStratagemBounce = state
    local original_update = update
    local attempted = false
    local callback
    local function report(message)
        print('[BetterStratagemBounce] ' .. build.revision .. ': ' .. message)
        pcall(function()
            local logger=rawget(_G,'CowboyBingusModLoader')
            local file=logger and logger.open_log and logger.open_log('BetterStratagemBounce.log')
            if file then file:write(build.revision .. '\n' .. message .. '\n'); file:close() end
        end)
    end
    local function initialize()
        if attempted then return end
        attempted = true
        local ok, result = pcall(function()
            local api = create_api()
            local exe, game = api.module(nil), api.module('game.dll')
            assert(exe and game, 'Required game modules unavailable')
            assert(api.module_hash(exe) == build.exe_sha256, 'Unsupported executable; no change applied')
            assert(api.module_hash(game) == build.game_sha256, 'Unsupported game module; no change applied')
            local applied, reason = patch.apply(api, game)
            assert(applied, reason)
            return reason
        end)
        state.active, state.status = ok, tostring(result)
        report(tostring(result))
        -- A later mod may still own the outer update callback.
        if update == callback then update = original_update or function() end end
    end
    local function forward(...)
        initialize()
        return ...
    end
    callback = function(dt, ...)
        if original_update then return forward(original_update(dt, ...)) end
        initialize()
    end
    update = callback
end
