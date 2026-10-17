-- HD2-Addon: mods/cowboybingus/sound_systems_rebalanced
-- Sound Systems Rebalanced for Helldivers 2 Steam build 25480438.
-- The Super Destroyer's rooms set the Wwise state environment_shiphub_room as you walk through them, and the
-- war-table area (shiphub_view) lowers the music bus by 6 dB. Nothing resets that state when you leave the ship,
-- so a mission's music played 6 dB louder when you deployed from anywhere but the war table, most often when
-- joining a mission already in progress. This mod sets shiphub_view whenever a mission starts, so every mission
-- plays its music at the war-table level that most players hear. In missions that state changes only the music
-- bus; back on the ship its own triggers set the room again as the player walks between rooms (as after any
-- mission started from the war table).
-- Cost: every 0.25 s of game time one 4-byte read of the game state ([game.dll+0x3326340] + 0xAC21C); the frames
-- between do no system call. Entering a mission (state 6, preparing a mission, or 4, mission) calls the engine's
-- stingray.Wwise.set_state once and writes one log line. Nothing is written to game memory. A second deployed copy
-- does nothing.
local Mod = {VERSION = '1.0'}

local ffi = require('ffi')

Mod.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
Mod.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

-- Build 25480438: the game object's static pointer and its game state (1 splash, 2 title, 5 preparing the ship,
-- 3 ship, 6 preparing a mission, 4 mission; also read by Hellpod Drop Hold). Tests pass their own layout.
Mod.LAYOUT = {game_rva = 0x3326340, state_offset = 0xAC21C}
Mod.MISSION_STATES = {[6] = true, [4] = true}
Mod.MAX_STATE = 64          -- a larger value means the game object moved: resolve its pointer again
Mod.CHECK_SECONDS = 0.25    -- game time between two reads of the game state
Mod.FALLBACK_DT = 1 / 60    -- frame time when the update chain passes no number
-- Wwise names (FNV-1 hashed by Wwise): the state group 0xEC643124 and its value 0x08EEC31C.
Mod.GROUP, Mod.ROOM = 'environment_shiphub_room', 'shiphub_view'

-- Raises reason without a source position, so the log line reads as the reason.
local function need(value, reason)
    if not value then error(reason, 0) end
    return value
end

-- The watcher. api: bingus_memory.lua's api (read_into only); game: game.dll's base as uint8_t *; set_state(group,
-- value): sets a global Wwise state by name; note(line): the log; state: the status table (missions, status).
function Mod.new(api, game, set_state, note, state, layout)
    layout = layout or Mod.LAYOUT
    local self = {}
    local slot = game + layout.game_rva
    local pointer_buffer = ffi.new('uint64_t[1]')
    local state_buffer = ffi.new('uint32_t[1]')
    local state_address = nil
    local elapsed, in_mission = Mod.CHECK_SECONDS, false -- the first frame reads at once

    local function resolve()
        state_address = nil
        if not api.read_into(slot, 8, pointer_buffer) then return false end
        local object = tonumber(pointer_buffer[0])
        if object < 0x10000 or object >= 0x800000000000 then return false end
        state_address = ffi.cast('uint8_t *', object + layout.state_offset)
        return true
    end

    -- The game state, or nil while the game object is missing or the read fails.
    local function game_state()
        if state_address == nil and not resolve() then return nil end
        if not api.read_into(state_address, 4, state_buffer) then
            state_address = nil
            return nil
        end
        local value = state_buffer[0]
        if value > Mod.MAX_STATE then
            state_address = nil
            return nil
        end
        return value
    end

    local function enter_mission(value)
        set_state(Mod.GROUP, Mod.ROOM)
        state.missions = state.missions + 1
        state.status = 'held mission music at the war-table level ' .. state.missions .. ' time(s)'
        note(string.format('Mission start (game state %d): music held at the war-table level (%s = %s).', value,
            Mod.GROUP, Mod.ROOM))
    end

    function self.step(dt)
        elapsed = elapsed + (tonumber(dt) or Mod.FALLBACK_DT)
        if elapsed < Mod.CHECK_SECONDS then return end
        elapsed = 0
        local value = game_state()
        if value == nil then return end
        local mission = Mod.MISSION_STATES[value] == true
        if mission and not in_mission then enter_mission(value) end
        in_mission = mission
    end

    -- An update below raised: start fresh (the next mission state sets the room again; setting it twice is
    -- harmless).
    function self.pause()
        elapsed, in_mission, state_address = Mod.CHECK_SECONDS, false, nil
    end

    function self.stopped(reason)
        state.status = 'stopped: ' .. tostring(reason)
        note(string.format('Stopped (%s) after %d mission(s).', tostring(reason), state.missions))
    end

    return self
end

-- The engine's Wwise Lua binding (stingray.Wwise.set_state), or nil.
function Mod.engine_set_state(globals)
    local ok, set_state = pcall(function()
        local stingray = rawget(globals or _G, 'stingray')
        return stingray and stingray.Wwise and stingray.Wwise.set_state
    end)
    if ok and type(set_state) == 'function' then return set_state end
    return nil
end

local function log_writer(loader)
    local file
    if type(loader) == 'table' and type(loader.open_log) == 'function' then
        pcall(function() file = loader.open_log('SoundSystemsRebalanced.log') end)
    end
    return function(line)
        print('[SoundSystemsRebalanced] ' .. line)
        if file then pcall(function() file:write(line .. '\n'); file:flush() end) end
    end
end

-- Installs the mod. runtime: bingus_runtime.lua; api: bingus_memory.lua's api. options: env (the table holding
-- update and shutdown, default _G), loader (default the global Bingus Shared Loader), set_state (default the
-- engine's stingray.Wwise.set_state), layout. Returns the status table.
function Mod.install(runtime, api, options)
    options = options or {}
    local env = options.env or _G
    local loader = options.loader or rawget(_G, 'CowboyBingusModLoader')
    local state = {version = Mod.VERSION, status = 'starting', missions = 0}
    rawset(env, 'SoundSystemsRebalanced', state)
    local note = log_writer(loader)
    local ok, instance = pcall(function()
        need(type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function',
            'Bingus Shared Loader with API 1 required')
        local built, why = api.verify_build({exe_sha256 = Mod.EXE_SHA256, game_sha256 = Mod.GAME_SHA256})
        need(built, why == 'unsupported game build' and 'unsupported game build (needs Steam build 25480438)'
            or tostring(why))
        local game = need(api.module('game.dll'), 'game.dll not loaded')
        local set_state = need(options.set_state or Mod.engine_set_state(env),
            "the engine's stingray.Wwise.set_state is unavailable")
        return Mod.new(api, game, set_state, note, state, options.layout)
    end)
    if not ok then
        state.status = 'disabled: ' .. tostring(instance)
        note('Sound Systems Rebalanced v' .. Mod.VERSION .. ' disabled: ' .. tostring(instance))
        return state
    end
    runtime.guard({name = 'SoundSystemsRebalanced', step = instance.step, stop = instance.stopped, pause = instance.pause,
                   log = note, env = env}).install()
    state.status = 'watching for mission starts'
    note('Sound Systems Rebalanced v' .. Mod.VERSION .. ': watching for mission starts.')
    return state
end

return Mod
