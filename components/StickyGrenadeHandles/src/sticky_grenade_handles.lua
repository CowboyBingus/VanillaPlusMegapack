-- HD2-Addon: mods/cowboybingus/sticky_grenade_handles
-- Sticky Grenade Handles for Helldivers 2 Steam build 25480438.
-- The G-123 Thermite and the sticky stun grenade bounce off when their handle touches first. The handle is a
-- separate capsule with its own physics material, sticky_grenade_handle, and the game sticks a throwable only
-- on contacts whose material tag equals the throwable's sticky material (ThrowableComponent +0x164, the
-- "throwable" material). This mod gives the handle material the throwable tag: one 4-byte write per session
-- into the engine's material library (the userData of one hknpMaterial). Friction, restitution and every
-- other value stay vanilla, and no other object in the game uses that material.
-- Cost: the write happens once. The game loads its entity settings a few seconds after the loader starts
-- addons, so a self-removing update hook waits for them at the splash screen (one or two reads per frame), then
-- checks and writes once and removes itself; nothing runs per frame after that. One read at shutdown logs
-- whether the value held. A second deployed copy does nothing.
local Mod = {VERSION = '1.0'}

Mod.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
Mod.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

-- Build 25480438. Tests pass their own layout.
Mod.LAYOUT = {
    library_rva = 0x27C5CF0,        -- helldivers2.exe: the hknpMaterialLibrary that tags each contact event
                                    -- with its shape's material (contact poster 0x78BFC0)
    library_vtable_rva = 0x148BA78, -- helldivers2.exe: hknpMaterialLibrary's vtable (RTTI)
    settings_rva = 0x346BF98,       -- game.dll: entity settings root (ThrowableComponent getter 0x50CD90)
    throwable_table = 0xF12C90,     -- settings root +: ThrowableComponentData
    throwable_slots = 92,           -- 16-byte slots {resource hash, record index}
    throwable_records = 1472,       -- records start right after the slots
    throwable_size = 360,
}
local ENTRY_SIZE, NAME, TAG = 80, 0x00, 0x48 -- hknpMaterial: name (hkStringPtr), userData (low dword)
local ENTRIES, COUNT, CAPACITY = 0x48, 0x50, 0x54 -- hknpMaterialLibrary: its entry array (hkArray)
local HEADER_SIZE, MAX_ENTRIES, CAPACITY_BITS = 0x58, 1024, 2 ^ 30 -- hkArray keeps flags in the top 2 bits
local BLOCK_HEADER, BLOCK_MAGIC = 24, 0x444C444C -- every settings block starts 24 bytes early with 'LDLD', 1, ...
local STICKY, STICKY_MATERIAL = 0x54, 0x164      -- ThrowableComponent: sticky, the material it sticks with
Mod.WAIT_SECONDS = 600 -- the fallback hook gives up after this much game time without the engine's data

Mod.THROWABLE = 0xC4692706 -- thin hash of the material name "throwable"
Mod.HANDLE = 0x9A056E1C    -- thin hash of "sticky_grenade_handle"
-- The two throwables built with the handle material (resource hash low and high words).
Mod.GRENADES = {
    {name = 'G-123 Thermite', lo = 0x5747C799, hi = 0xC5C05FCB},
    {name = 'sticky stun grenade', lo = 0xF596BC0B, hi = 0x3FA94F58},
}

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
local THROWABLE_BYTES = le32(Mod.THROWABLE)

-- The material library and its entry array, or nil while the engine has not created it. Raises when the
-- object is not an hknpMaterialLibrary or its array is implausible.
function Mod.library(api, exe, layout)
    local library = api.pointer(api.read(exe + layout.library_rva, 8))
    if not library then return nil end
    local header = need(api.read(library, HEADER_SIZE), 'Material library unreadable')
    local vtable = api.pointer(header, 0)
    need(vtable and api.distance(vtable, exe) == layout.library_vtable_rva, 'Unexpected material library')
    local entries = need(api.pointer(header, ENTRIES), 'Material entries unavailable')
    local count, capacity = u32(header, COUNT), u32(header, CAPACITY) % CAPACITY_BITS
    need(count > 0 and count <= MAX_ENTRIES and count <= capacity, 'Unexpected material count')
    return {entries = entries, count = count}
end

-- Whether entry index is named expected. Names are hkStringPtr: bit 0 of the pointer is an ownership flag.
local function named(api, bytes, index, expected)
    local offset = index * ENTRY_SIZE + NAME
    local pointer = api.pointer(bytes, offset)
    if not pointer then return false end
    return api.read(pointer - bytes:byte(offset + 1) % 2, #expected + 1) == expected .. '\0'
end

-- Indexes of the handle and throwable materials (nil when absent) and whether the handle already carries the
-- throwable tag. Raises when a name occurs twice.
function Mod.find_materials(api, library)
    local bytes = need(api.read(library.entries, library.count * ENTRY_SIZE), 'Material entries unreadable')
    local handle, throwable, applied
    for index = 0, library.count - 1 do
        local tag = u32(bytes, index * ENTRY_SIZE + TAG)
        if (tag == Mod.HANDLE or tag == Mod.THROWABLE) and named(api, bytes, index, 'sticky_grenade_handle') then
            need(not handle, 'Two sticky_grenade_handle materials')
            handle, applied = index, tag == Mod.THROWABLE
        elseif tag == Mod.THROWABLE and named(api, bytes, index, 'throwable') then
            need(not throwable, 'Two throwable materials')
            throwable = index
        end
    end
    return handle, throwable, applied
end

-- The grenade's ThrowableComponent record, or nil when the table has no slot for it.
local function grenade_record(api, settings, grenade, layout)
    for slot = 0, layout.throwable_slots - 1 do
        local offset = slot * 16
        if u32(settings.slots, offset) == grenade.lo and u32(settings.slots, offset + 4) == grenade.hi then
            local start = layout.throwable_records + u32(settings.slots, offset + 8) * layout.throwable_size
            need(start + layout.throwable_size <= settings.size, 'Throwable record out of bounds')
            return api.read(settings.table + start, layout.throwable_size)
        end
    end
end

-- The ThrowableComponent settings block, or nil while the game has not loaded its entity settings (1 read
-- while the settings root is unset, 2 while its table is).
function Mod.throwable_settings(api, game, layout)
    local root = api.pointer(api.read(game + layout.settings_rva, 8))
    local table = root and api.pointer(api.read(root + layout.throwable_table, 8))
    if not table then return nil end
    local header = need(api.read(table - BLOCK_HEADER, BLOCK_HEADER), 'Throwable settings unreadable')
    need(u32(header, 0) == BLOCK_MAGIC and u32(header, 4) == 1, 'Unexpected throwable settings block')
    local slots = need(api.read(table, layout.throwable_slots * 16), 'Throwable settings unreadable')
    return {table = table, slots = slots, size = u32(header, 12)}
end

-- Raises unless both grenades are sticky and stick only on contacts tagged with the throwable material, the
-- premise of the change. A data-only game update can change these without changing the binaries the build
-- check covers, so they are checked every session.
function Mod.check_grenades(api, settings, layout)
    for _, grenade in ipairs(Mod.GRENADES) do
        local record = need(grenade_record(api, settings, grenade, layout),
            'No throwable settings for the ' .. grenade.name)
        need(record:byte(STICKY + 1) == 1 and u32(record, STICKY_MATERIAL) == Mod.THROWABLE,
            'The ' .. grenade.name .. ' no longer sticks by the throwable material')
    end
end

-- One attempt: 'applied' or 'already applied' with the handle material's tag address and index, or 'wait'
-- with what the engine has not loaded yet. Raises when anything differs from build 25480438's data; nothing is
-- written then. The entity settings come first: they are the cheapest check and load last (live: about 6 s
-- after the loader starts addons, when the materials have long been there).
function Mod.attempt(api, exe, game, layout)
    local settings = Mod.throwable_settings(api, game, layout)
    if not settings then return 'wait', 'the throwable settings are not loaded yet' end
    local library = Mod.library(api, exe, layout)
    if not library then return 'wait', 'the material library does not exist yet' end
    local handle, throwable, applied = Mod.find_materials(api, library)
    if not handle and not throwable then return 'wait', 'the materials are not loaded yet' end
    need(handle, 'No sticky_grenade_handle material')
    need(throwable, 'No throwable material')
    Mod.check_grenades(api, settings, layout)
    local tag = library.entries + handle * ENTRY_SIZE + TAG
    if applied then return 'already applied', tag, handle end
    -- One protection query right before the write: only committed private read-write memory is written.
    need(api.write(tag, THROWABLE_BYTES), 'Material write refused or failed')
    need(api.read(tag, 4) == THROWABLE_BYTES, 'Material write did not hold')
    return 'applied', tag, handle
end

-- Waits for the engine with a self-removing update hook. The previous update runs first, outside pcall, so its
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

-- Logs once at shutdown whether the handle material still carries the throwable tag. The previous shutdown
-- runs after the check, outside pcall.
function Mod.check_at_shutdown(env, api, state, note)
    local previous = env.shutdown
    env.shutdown = function(...)
        pcall(function()
            if state.tag then
                local held = api.read(state.tag, 4) == THROWABLE_BYTES
                note(held and 'At shutdown: the handle material still sticks.'
                    or 'At shutdown: the handle material lost the throwable tag.')
            end
        end)
        if previous then return previous(...) end
    end
end

local function open_log(loader)
    local file
    if type(loader) == 'table' and type(loader.open_log) == 'function' then
        pcall(function() file = loader.open_log('StickyGrenadeHandles.log') end)
    end
    return function(line)
        print('[StickyGrenadeHandles] ' .. line)
        if file then pcall(function() file:write(line .. '\n'); file:flush() end) end
    end
end

local function loader_ok(loader)
    return type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function'
end

local function applied_text(result, state)
    return result .. ' (material ' .. state.index .. ' tagged throwable: the handles of the G-123 Thermite and '
        .. 'the sticky stun grenade stick)'
end

-- The attempt at load, then the fallback hook if the engine is not ready.
local function start(env, api, layout, state, note)
    local exe, game = api.module(nil), api.module('game.dll')
    -- True when done; false and what the game has not loaded yet otherwise.
    local function try_once()
        local result, detail, index = Mod.attempt(api, exe, game, layout)
        if result == 'wait' then
            state.status = 'waiting: ' .. detail
            return false, detail
        end
        state.tag, state.index, state.applied = detail, index, true
        state.status = applied_text(result, state)
        return true
    end
    local done, missing = try_once()
    if done then
        note(state.status .. ', at load.')
        return
    end
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
    end)
end

-- Installs the mod. api: bingus_memory.lua's api extended by bingus_write.lua. options: env (the table holding
-- update and shutdown, default _G), layout, loader (default the global Bingus Shared Loader).
function Mod.install(api, options)
    options = options or {}
    local env, layout = options.env or _G, options.layout or Mod.LAYOUT
    local loader = options.loader or rawget(_G, 'CowboyBingusModLoader')
    local state = {version = Mod.VERSION, status = 'starting', applied = false}
    env.StickyGrenadeHandles = state
    local note = open_log(loader)
    local ok, err = pcall(function()
        need(loader_ok(loader), 'Bingus Shared Loader with API 1 required')
        local built, why = api.verify_build({exe_sha256 = Mod.EXE_SHA256, game_sha256 = Mod.GAME_SHA256})
        need(built, why == 'unsupported game build' and 'Unsupported game build (needs Steam build 25480438)'
            or why)
        start(env, api, layout, state, note)
    end)
    if not ok then
        state.status = 'disabled: ' .. tostring(err)
        note('Sticky Grenade Handles v' .. Mod.VERSION .. ' disabled: ' .. tostring(err))
        return state
    end
    Mod.check_at_shutdown(env, api, state, note)
    return state
end

return Mod
