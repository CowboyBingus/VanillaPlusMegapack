-- HD2-Addon: mods/cowboybingus/foliage_pass_through
-- Foliage Pass-Through for Helldivers 2 Steam build 25480438.
-- Rockets, launcher rounds and stratagem ordnance explode in tree canopies and bushes. Every projectile casts its
-- flight ray with the collision query its ProjectileInfo row names (raycast_template, +0xF4; the simulation
-- game.dll 0x13AB0E0 reads it every step). Template 0 is damage_query, which collides with the 'foliage' layer
-- (tree canopies, bushes); template 2 is damage_no_foliage_query, the same query without that layer. The game
-- already gives plasma bolts and lasers template 2. This mod gives it to the player-side projectiles that explode
-- on impact (foliage_targets.lua): one 4-byte write per row, once per session, in the loaded projectile settings
-- (committed private read-write memory, as Better Stratagem Bounce's stratagem settings). Trunks and limbs ('wood'
-- on the 'default' layer), terrain, buildings and every unit still stop them. Enemy projectiles stay vanilla.
-- Cost: once per session, an index read, one read per row, one checked batch write and one read-back per row;
-- a self-removing update hook waits (1 read per frame) if the settings are not loaded yet. Nothing runs per frame
-- after that. One read per row at shutdown logs whether the change held. An optional diagnostics module (the
-- developer's test builds only) is installed after the change; release builds have none.
local Mod = {VERSION = '1.0'}

Mod.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
Mod.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

-- Build 25480438. Tests pass their own layout.
Mod.LAYOUT = {
    buffer_rva = 0x348E2F8, -- game.dll: the loaded generated_projectile_settings buffer (loader 0x11EC5A0)
    index_rva = 0x37C7670,  -- game.dll: ProjectileInfo* per ProjectileType, filled by the same loader
    slots = 351,            -- index slots (the loader clears 2808 bytes)
    row_size = 0x110,       -- ProjectileInfo
}
local TYPE, NAME, EXPLOSION, TEMPLATE = 0x00, 0x08, 0x90, 0xF4 -- ProjectileInfo fields the mod checks or writes
Mod.VANILLA, Mod.NO_FOLIAGE = 0, 2 -- RaycastTemplate_Damage, RaycastTemplate_DamageNoFoliage
Mod.WAIT_SECONDS = 600 -- the fallback hook gives up after this much game time without the settings
-- {type, name hash, impact explosion, label}; set by the addon entry (foliage_targets.lua).
Mod.TARGETS = {} -- lint-ok: R14 need/u32/le32 as in Sticky Grenade Handles; each mod loads and is tested alone

-- assert without the file:line prefix: these messages go to the user's log.
local function need(value, message)
    if not value then error(message, 0) end
    return value
end

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function le32(value)
    return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256)
end
local BYTES = {[Mod.VANILLA] = le32(Mod.VANILLA), [Mod.NO_FOLIAGE] = le32(Mod.NO_FOLIAGE)}

-- One target's row: its pointer and current template. Raises unless the row is the expected projectile with an
-- impact explosion and a template this mod knows (0 vanilla, 2 changed).
local function target_row(api, index, target, layout)
    local ptype, name, explosion, label = target[1], target[2], target[3], target[4]
    need(ptype < layout.slots, 'Projectile type out of range: ' .. label)
    local pointer = need(api.pointer(index, ptype * 8), 'No projectile settings for ' .. label)
    local row = need(api.read(pointer, layout.row_size), 'Projectile settings unreadable: ' .. label)
    need(u32(row, TYPE) == ptype and u32(row, NAME) == name and u32(row, EXPLOSION) == explosion,
        'Unexpected projectile settings for ' .. label .. ' (type ' .. ptype .. ')')
    local template = u32(row, TEMPLATE)
    need(template == Mod.VANILLA or template == Mod.NO_FOLIAGE,
        'Unexpected raycast template ' .. template .. ' for ' .. label)
    return {pointer = pointer, template = template, target = target}
end

-- The target rows, or nil and what is missing while the game has not loaded its projectile settings. The result
-- also holds the span [base, base + size) that covers every row's template field, for one checked batch write.
function Mod.rows(api, game, layout, targets)
    if not api.pointer(api.read(game + layout.buffer_rva, 8)) then
        return nil, 'the projectile settings are not loaded yet'
    end
    local index = need(api.read(game + layout.index_rva, layout.slots * 8), 'Projectile index unreadable')
    local list, low, high = {}, nil, nil
    for i, target in ipairs(targets) do
        local row = target_row(api, index, target, layout)
        local at = api.address(row.pointer)
        low, high = math.min(low or at, at), math.max(high or at, at)
        list[i] = row
    end
    need(#list > 0, 'No projectiles to change')
    for _, row in ipairs(list) do row.offset = api.address(row.pointer) - low + TEMPLATE end
    local base = list[1].pointer - (api.address(list[1].pointer) - low)
    return {list = list, base = base, size = high - low + TEMPLATE + 4}
end

-- Sets every row whose template differs from value; returns how many changed. The writes land under one page
-- check; when only some land, the ones that did are put back before raising. Reads each changed field back.
function Mod.set_template(api, rows, value)
    local changes, changed = {}, {}
    for _, row in ipairs(rows.list) do
        if row.template ~= value then
            changes[#changes + 1] = {row.offset, BYTES[value]}
            changed[#changed + 1] = row
        end
    end
    if #changes == 0 then return 0 end
    local ok, landed = api.write_batch(rows.base, rows.size, changes)
    if not ok then
        local undo = {}
        for i = 1, landed or 0 do undo[i] = {changes[i][1], BYTES[changed[i].template]} end
        if #undo > 0 then api.write_batch(rows.base, rows.size, undo) end
        error('Projectile settings write refused or failed', 0)
    end
    for _, row in ipairs(changed) do
        need(api.read(row.pointer + TEMPLATE, 4) == BYTES[value], 'Projectile settings write did not hold')
        row.template = value
    end
    return #changes
end

-- Current templates of the rows, read again: counts of rows at 2, at 0, and of anything else.
function Mod.verify(api, rows)
    local changed, vanilla, other = 0, 0, 0
    for _, row in ipairs(rows.list) do
        local bytes = api.read(row.pointer + TEMPLATE, 4)
        if bytes == BYTES[Mod.NO_FOLIAGE] then changed = changed + 1
        elseif bytes == BYTES[Mod.VANILLA] then vanilla = vanilla + 1
        else other = other + 1 end
    end
    return changed, vanilla, other
end

-- One attempt: 'wait' and what is missing, or 'applied' with the rows and how many this attempt changed.
function Mod.attempt(api, game, layout, targets)
    local rows, missing = Mod.rows(api, game, layout, targets)
    if not rows then return 'wait', missing end
    return 'applied', rows, Mod.set_template(api, rows, Mod.NO_FOLIAGE)
end -- lint-ok: R14 the one-shot hook and its start as in Sticky Grenade Handles; each mod loads and is tested alone

-- Waits for the game with a self-removing update hook. The previous update runs first, outside pcall, so its
-- errors reach the game unchanged. try(dt) returns true when finished; an error also finishes. When finished,
-- the hook puts the previous update back if it is still the outermost one; otherwise it stays a pass-through.
function Mod.hook(env, try, finish)
    local previous = env.update
    local callback, done
    local function step(dt)
        if done then return end
        local ok, finished = pcall(try, dt)
        if ok and not finished then return end
        done = true
        finish(ok, finished)
        if env.update == callback then env.update = previous or function() end end
    end
    local function after(dt, ...)
        step(dt)
        return ...
    end
    callback = function(dt, ...)
        if previous then return after(dt, previous(dt, ...)) end
        step(dt)
    end
    env.update = callback
end

-- Logs once at shutdown whether the rows still use the no-foliage query. The previous shutdown runs after the
-- check, outside pcall.
function Mod.check_at_shutdown(env, api, state, note)
    local previous = env.shutdown
    env.shutdown = function(...)
        pcall(function()
            if state.rows then
                local changed, vanilla, other = Mod.verify(api, state.rows)
                note(('At shutdown: %d of %d projectile types use the no-foliage query (%d vanilla, %d other).')
                    :format(changed, #state.rows.list, vanilla, other))
            end
        end)
        if previous then return previous(...) end
    end
end

local function open_log(loader)
    local file
    if type(loader) == 'table' and type(loader.open_log) == 'function' then
        pcall(function() file = loader.open_log('FoliagePassThrough.log') end)
    end
    return function(line)
        print('[FoliagePassThrough] ' .. line)
        if file then pcall(function() file:write(line .. '\n'); file:flush() end) end
    end
end

local function loader_ok(loader)
    return type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function'
end

local function applied_text(rows, changed)
    return ('applied: %d projectile types use the no-foliage query (%d changed now, %d already changed)')
        :format(#rows.list, changed, #rows.list - changed)
end

-- The attempt at load, then the fallback hook if the settings are not loaded yet. ready(rows) runs once applied.
local function start(env, api, layout, state, note, ready)
    local game = api.module('game.dll')
    local function try_once()
        local result, rows, changed = Mod.attempt(api, game, layout, Mod.TARGETS)
        if result == 'wait' then
            state.status = 'waiting: ' .. rows
            return false, rows
        end
        state.rows, state.applied, state.patched = rows, true, true
        state.status = applied_text(rows, changed)
        return true
    end
    local done, missing = try_once()
    if done then
        note(state.status .. ', at load.')
        return ready()
    end -- lint-ok: R14 the wait hook's start as in Sticky Grenade Handles; each mod loads and is tested alone
    note('Waiting for the game: ' .. missing .. '.')
    local waited = 0
    Mod.hook(env, function(dt)
        if try_once() then return true end
        waited = waited + (tonumber(dt) or 0)
        need(waited < Mod.WAIT_SECONDS, 'gave up after ' .. Mod.WAIT_SECONDS .. ' s: ' .. state.status)
        return false
    end, function(ok, err)
        if not ok then state.status = 'disabled: ' .. tostring(err) end
        note(ok and (state.status .. ', after ' .. string.format('%.1f', waited) .. ' s.')
            or ('Disabled: ' .. tostring(err)))
        if ok then ready() end
    end)
end

-- The test builds' control of the change: switch every target row between the no-foliage query and vanilla.
local function control(api, state)
    return {
        state = state,
        set = function(patched)
            if not state.rows then return false, 'not applied' end
            local changed = Mod.set_template(api, state.rows, patched and Mod.NO_FOLIAGE or Mod.VANILLA)
            state.patched = patched
            return true, changed
        end,
        verify = function()
            if not state.rows then return nil end
            return Mod.verify(api, state.rows)
        end,
    }
end

-- Installs the mod. api: bingus_memory.lua's api extended by bingus_write.lua. options: env (the table holding
-- update and shutdown, default _G), layout, loader (default the global Bingus Shared Loader), diagnostics (test
-- builds: shot_log.lua's module) with diagnostics_options (passed through to it).
function Mod.install(api, options)
    options = options or {}
    local env, layout = options.env or _G, options.layout or Mod.LAYOUT
    local loader = options.loader or rawget(_G, 'CowboyBingusModLoader')
    local state = {version = Mod.VERSION, status = 'starting', applied = false, patched = false}
    env.FoliagePassThrough = state
    local note = open_log(loader)
    local function ready()
        if not options.diagnostics then return end
        local ok, err = pcall(options.diagnostics.install, api, control(api, state), note,
            options.diagnostics_options or {})
        if not ok then note('Shot log disabled: ' .. tostring(err)) end
    end
    local ok, err = pcall(function()
        need(loader_ok(loader), 'Bingus Shared Loader with API 1 required')
        local built, why = api.verify_build({exe_sha256 = Mod.EXE_SHA256, game_sha256 = Mod.GAME_SHA256})
        need(built, why == 'unsupported game build' and 'Unsupported game build (needs Steam build 25480438)'
            or why)
        start(env, api, layout, state, note, ready)
    end)
    if not ok then
        state.status = 'disabled: ' .. tostring(err)
        note('Foliage Pass-Through v' .. Mod.VERSION .. ' disabled: ' .. tostring(err))
        return state
    end
    Mod.check_at_shutdown(env, api, state, note)
    return state
end

return Mod
