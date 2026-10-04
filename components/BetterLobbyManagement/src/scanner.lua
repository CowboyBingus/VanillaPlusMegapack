-- Galactic Map lobby scanner recharge (Steam build 25480438), formerly the
-- standalone Fast Lobby Scanner.
--
-- The scanner copies the online config's recharge seconds into its countdown
-- each time a scan's results arrive (game.dll 0x1337fa8). This module keeps
-- that one config field at the player's setting, never above the game's own
-- value, and writes again whenever the game rewrites it (its online config
-- arrives at login and then about every 15 minutes).
local M = {}

M.CONFIG_PTR_RVA = 0x347cee0     -- online config object
M.RECHARGE = 0x3ce4c             -- int32 seconds; read only by the scanner
M.MATCHMAKING_PTR_RVA = 0x347ce80
M.COUNTDOWN = 0x10bd74           -- float seconds left ("SCANNER RECHARGING... N")
-- Settings: 5 s at the shortest, so the scanner's lobby searches never go
-- beyond one every ~5.3 s (5 s plus the search), about 4x the game's rate.
M.MIN_SECONDS, M.MAX_SECONDS, M.DEFAULT_SECONDS = 5, 20, 5
-- Game values outside this range are not treated as seconds. A game value
-- below the settings (a server that wants faster scans) is kept as it is.
M.GAME_VALUE_MIN, M.GAME_VALUE_LIMIT = 1, 3600
-- The game rewrites the field about every 15 minutes. Far more rewrites mean
-- something else keeps writing it; the mod then stops instead of paying a
-- page check every frame.
M.REWRITE_LIMIT = 500

-- Code this depends on, checked once per session before the first update.
M.CODE = {
    -- On entering "recharging": countdown = (float)[[game.dll+0x347cee0] + 0x3ce4c].
    {rva = 0x1337fa8, name = 'recharge reader', bytes =
        '\72\139\5\49\79\20\2' ..              -- mov rax, [rip+0x2144f31] (0x347cee0)
        '\69\139\206' ..                       -- mov r9d, r14d
        '\102\15\110\128\76\206\3\0' ..        -- movd xmm0, [rax+0x3ce4c]
        '\139\134\40\167\0\0' ..               -- mov eax, [rsi+0xa728]
        '\199\134\60\189\16\0\50\0\0\0' ..     -- mov dword [rsi+0x10bd3c], 50
        '\137\134\64\241\12\0' ..              -- mov [rsi+0xcf140], eax
        '\137\134\216\242\12\0' ..             -- mov [rsi+0xcf2d8], eax
        '\15\91\192' ..                        -- cvtdq2ps xmm0, xmm0
        '\243\15\17\134\116\189\16\0'},        -- movss [rsi+0x10bd74], xmm0
    -- Every frame: if countdown > 0 then countdown -= dt.
    {rva = 0x133752e, name = 'countdown update', bytes =
        '\243\15\16\129\116\189\16\0' ..       -- movss xmm0, [rcx+0x10bd74]
        '\15\47\198\118\12' ..                 -- comiss xmm0, xmm6; jbe +12
        '\243\15\92\199' ..                    -- subss xmm0, xmm7
        '\243\15\17\129\116\189\16\0'},        -- movss [rcx+0x10bd74], xmm0
    -- A scanner setter: the matchmaking global holds the object with the
    -- scanner fields (+0x10bd5d here, the countdown at +0x10bd74).
    {rva = 0x133e9e0, name = 'matchmaking global', bytes =
        '\72\139\5\153\228\19\2' ..            -- mov rax, [rip+0x213e499] (0x347ce80)
        '\136\144\93\189\16\0' ..              -- mov [rax+0x10bd5d], dl
        '\195'},                               -- ret
}

local function whole_seconds(value)
    if type(value) ~= 'number' or value ~= value then return nil end
    return math.max(M.MIN_SECONDS, math.min(M.MAX_SECONDS, math.floor(value + 0.5)))
end

local function plausible_pointer(value)
    return value >= 0x10000 and value < 0x800000000000 and value % 8 == 0
end

-- s: the table the addon keeps as its status; counts are kept there, and
-- s.revision changes whenever any of them does (one number to watch per frame).
function M.new(api, game, s)
    local self = {}
    s.status, s.writes, s.refreshes, s.shortened = 'waiting_for_config', 0, 0, 0
    s.setting, s.game_value, s.applied, s.revision = M.DEFAULT_SECONDS, nil, nil, 0
    local config_global, matchmaking_global = game + M.CONFIG_PTR_RVA, game + M.MATCHMAKING_PTR_RVA
    -- config: the object read32 confirmed, 0 while there is none; field: its
    -- recharge address. owner: the object settled and s.game_value describe.
    -- settled: the field value at which there is nothing to do. dirty: run
    -- the slow path next check.
    local config, field, owner, settled, dirty, stopped = 0, 0, 0, nil, false, false
    local function set_status(status)
        if s.status ~= status then s.status, s.revision = status, s.revision + 1 end
    end

    -- Shortens the running countdown to seconds when it is longer; a failure
    -- here only leaves one recharge at the old length.
    local function shorten(seconds)
        local matchmaking = api.load64(matchmaking_global)
        if not plausible_pointer(matchmaking) then return end
        local left = api.read_f32(matchmaking + M.COUNTDOWN)
        if not left or left ~= left or left <= seconds or left > M.GAME_VALUE_LIMIT then return end
        if api.write_f32(matchmaking + M.COUNTDOWN, seconds) then s.shortened = s.shortened + 1 end
    end

    -- The slow path: the field changed, the setting changed or the config
    -- object changed. Returns false after stopping. The revision moves for a
    -- new status or a new game value, not for the game rewriting its usual one.
    local function settle(current)
        dirty = false
        if current ~= settled then
            -- The game wrote the field, or this is the first look: its value.
            if settled ~= nil then
                s.refreshes = s.refreshes + 1
                if s.refreshes > M.REWRITE_LIMIT then
                    stopped = true
                    set_status('field_contended')
                    return false
                end
            end
            if current ~= s.game_value then s.game_value, s.revision = current, s.revision + 1 end
        end
        local game_value = s.game_value
        if game_value < M.GAME_VALUE_MIN or game_value > M.GAME_VALUE_LIMIT then
            -- 0: the object exists but the game has not filled it in yet (boot).
            settled, s.applied = current, nil
            set_status(game_value == 0 and 'waiting_for_game_value' or 'unexpected_game_value')
            return true
        end
        local seconds = math.min(s.setting, game_value)
        if seconds ~= current then
            if not api.write32(field, seconds) or api.load32(field) ~= seconds then
                stopped = true
                set_status('config_write_failed')
                return false
            end
            s.writes = s.writes + 1
            -- A scan result may already have used the old value this frame.
            if seconds < game_value then shorten(seconds) end
        end
        settled, s.applied = seconds, seconds
        set_status(seconds < game_value and 'active' or 'game_value_kept')
        return true
    end

    -- One check per frame. Idle (nothing changed): two direct loads.
    function self.check()
        if stopped then return false end
        local object = api.load64(config_global)
        if object ~= config or object == 0 then
            if object == 0 then
                config = 0
                set_status('waiting_for_config')
                return true
            end
            if not plausible_pointer(object) or not api.read32(object + M.RECHARGE) then
                -- Not confirmed readable: keep config at 0 and ask again next frame.
                config = 0
                set_status('waiting_for_config_read')
                return true
            end
            if object ~= owner then owner, settled, s.game_value, s.applied = object, nil, nil, nil end
            config, field, dirty = object, object + M.RECHARGE, true
        end
        local current = api.load32(field)
        if current == settled and not dirty then return true end
        return settle(current)
    end

    -- A setting from Mod Options Menu (or the default); the next check applies it.
    function self.set_setting(value)
        local seconds = whole_seconds(value)
        if not seconds then return false end
        if seconds ~= s.setting then s.setting, dirty, s.revision = seconds, true, s.revision + 1 end
        return true
    end

    -- Puts the game's value back while the field still holds this module's.
    -- Returns false only when that write failed.
    local function put_back()
        if config == 0 or config ~= owner or settled == nil or s.game_value == nil
            or settled == s.game_value then return true end
        if api.read32(field) ~= settled then return true end
        if not api.write32(field, s.game_value) then return false end
        settled = s.game_value -- the field holds the game's value now: not a rewrite
        return true
    end

    -- Stops checking and puts the game's value back when the field still
    -- holds this module's value. Returns false only when that write failed.
    function self.stop(reason)
        stopped, s.status, s.revision = true, reason or s.status, s.revision + 1
        return put_back()
    end

    -- The addon's pause after an error below it: the game's value goes back
    -- as on stop, and after resume() the next check confirms the object again
    -- and applies the setting (the counts stay). A stop stays a stop.
    local paused = false
    function self.pause(reason)
        if stopped then return true end
        paused = true
        return self.stop(reason)
    end
    function self.resume()
        if not paused then return false end
        paused, stopped, config, dirty = false, false, 0, true
        set_status('waiting_for_config')
        return true
    end

    return self
end

M.whole_seconds = whole_seconds
return M
