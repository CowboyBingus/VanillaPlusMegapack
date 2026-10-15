-- HD2-Addon: mods/cowboybingus/stratagem_hero_expanded
-- Stratagem Hero Expanded for Helldivers 2 Steam build 25480438.
-- The ship's Stratagem Hero arcade draws its stratagems from two fixed tables in game.dll's writable data
-- section: 9 round tiers, each a weighted list of up to 8 groups, and 10 groups of up to 16 stratagem types (the
-- picker is game.dll 0x598370, called by the arcade's round logic 0x5970D0). Vanilla reaches 27 launch-era
-- stratagems. This mod rewrites both tables once per session so the arcade draws from every stratagem a loadout
-- can hold plus the mission stratagems every squad calls (108). It keeps the four themed rounds and their
-- banners, and gives every stratagem the same odds in the other rounds. Nothing else changes: the game's own
-- picker, widget and input check read the new tables.
-- Cost: the write happens once. The stratagem settings the mod checks first may load after the loader starts
-- addons, so a self-removing update hook can wait for them (one read per frame), then checks and writes once and
-- removes itself; nothing runs per frame after that. One read at shutdown logs whether the tables held. A second
-- deployed copy does nothing.
local Mod = {VERSION = '1.0'}

local ffi = require('ffi')

Mod.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
Mod.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

-- Build 25480438. Tests pass their own layout.
Mod.LAYOUT = {
    tiers_rva = 0x263CCC0,    -- game.dll: 9 tiers of 68 bytes {u32 banner, 8 x {u32 group, f32 weight}}
    groups_rva = 0x263CF70,   -- game.dll: 10 groups of 64 bytes, up to 16 u32 stratagem types, 0 ends a group
    settings_rva = 0x37CB600, -- game.dll: StratagemInfo pointers by stratagem type (8 bytes each)
}
local TIERS, TIER_SIZE, TIER_ENTRIES = 9, 68, 8
local GROUPS, GROUP_SIZE, GROUP_SLOTS = 10, 64, 16
local TYPES = 150 -- StratagemType values of this build, None (0) included
-- StratagemInfo: its type, its code (dl_array: pointer, then count) and its HUD type, which colours the arcade's
-- icon (5 colours). The arcade's widget lays out at most 10 arrows.
local INFO_SIZE, INFO_TYPE, INFO_CODE, INFO_CODE_LENGTH, INFO_HUD = 0xC0, 0x00, 0x40, 0x48, 0xB8
local MAX_CODE, MAX_HUD = 10, 4
local MEM_COMMIT, MEM_IMAGE = 0x1000, 0x1000000
-- Writable page protections: read-write, copy-on-write and their executable forms (a packed module may keep its
-- data pages executable). The address is a data-section variable whose exact bytes are checked first.
local WRITABLE = {[0x04] = true, [0x08] = true, [0x40] = true, [0x80] = true}
Mod.WAIT_SECONDS = 600 -- the fallback hook gives up after this much game time without the stratagem settings
Mod.PROBE = 124 -- Reinforce: once its settings pointer is set, the stratagem settings are loaded

-- Build 25480438's tables, checked byte for byte before anything is written.
Mod.VANILLA_TIERS = {
    {banner = 1197656392, {6, 1.0}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}, -- BACK-PACKING A PUNCH
    {banner = 1224989586, {4, 1.0}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}, -- FLY LIKE AN EAGLE
    {banner = 4059426536, {7, 1.0}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}, -- RAIN DOWN FROM ABOVE
    {banner = 2594389917, {9, 0.6}, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}}, -- OVERWHELMING FIREPOWER
    {banner = 0, {1, 0.5}, {2, 0.2}, {3, 0.05}, {8, 0.075}},
    {banner = 0, {1, 0.6}, {2, 0.4}, {3, 0.1}, {8, 0.075}},
    {banner = 0, {1, 0.3}, {2, 0.5}, {3, 0.4}, {8, 0.075}},
    {banner = 0, {1, 0.1}, {2, 0.5}, {3, 0.5}, {8, 0.075}},
    {banner = 0, {1, 0.1}, {2, 0.2}, {3, 0.8}, {8, 0.1}},
}
Mod.VANILLA_GROUPS = { -- groups 1-9; group 0 is empty (0 ends a tier's list, so it is never picked)
    {83, 136, 33, 30, 119, 66},
    {3, 140, 125, 107, 92, 130, 42, 147, 53, 117},
    {43, 73, 134, 25, 141, 144},
    {30, 3, 140, 18},
    {137, 66, 117, 53}, -- no tier lists this group
    {43, 73, 134},
    {83, 136, 125, 107},
    {124},
    {56, 13, 63},
}

-- The new pool: the 96 stratagems this build's settings mark selectable for a loadout, and the 12 mission
-- stratagems every squad calls. Stratagem types of build 25480438, grouped by the class each stratagem's settings
-- give it (StratagemInfo +0x188: 1-6 orbitals, 7-10 Eagles, 11-20 support weapons, 21-24 backpacks, 26-28
-- vehicles, 29-32 sentries, 33-35 emplacements, 36 mines, 0 mission), in the order of those classes. A round draws
-- from at most 8 groups, so sentries share a group with emplacements and vehicles with mines; neither pair is a
-- theme, and every group's weight follows its size, so sharing changes no stratagem's odds.
Mod.GROUPS = {
    { -- 1, backpacks: Supply Pack, Portable Hellbomb, C4 Pack, Jump Pack, Hover Pack, Warp Pack, Ballistic Shield,
      -- Directional Shield, Shield Generator Pack, Guard Dog, Rover, Dog Breath, Hot Dog, K-9
        101, 120, 14, 134, 55, 24, 96, 67, 43, 73, 115, 142, 57, 2},
    { -- 2, Eagles: Strafing Run, 500kg Bomb, Eagle Rearm, 110mm Rocket Pods, Airstrike, Napalm Airstrike, Cluster
      -- Bomb, Gas Airstrike, Smoke Strike
        30, 3, 49, 140, 18, 133, 65, 126, 38},
    { -- 3, orbitals: Precision Strike, Airburst Strike, Gatling Barrage, 120mm HE Barrage, Napalm Barrage, 380mm HE
      -- Barrage, Walking Barrage, Walking Barrage Smoke, Laser, Railcannon Strike, Gas Strike, Smoke Strike, EMS
      -- Strike
        118, 83, 4, 136, 106, 125, 21, 62, 107, 58, 41, 74, 34},
    { -- 4, support weapons: One True Flag, Defoliation Tool, Breaching Hammer, Machine Gun, Heavy Machine Gun,
      -- Stalwart, Railgun, Speargun, Anti-Materiel Rifle, Grenade Launcher, De-Escalator, Epoch, Meltagun,
      -- Flamethrower, Sterilizer, Laser Cannon
        114, 51, 100, 92, 32, 13, 56, 113, 141, 80, 131, 45, 81, 112, 61, 63},
    { -- 5, support weapons: Quasar Cannon, Arc Thrower, Expendable Anti-Tank, Expendable Napalm, Leveller, Commando,
      -- Bullet Storm, Solo Silo, Autocannon, Belt-Fed Grenade Launcher, Recoilless Rifle, Airburst Rocket Launcher,
      -- Spear, W.A.S.P. Launcher, Maxigun, Cremator
        149, 68, 147, 39, 16, 6, 99, 89, 25, 127, 130, 54, 75, 97, 110, 87},
    { -- 6, sentries and emplacements: Machine Gun, Gatling, Flame, Laser, Rocket, Autocannon, Mortar, EMS Mortar and
      -- Gas Mortar Sentries, Grenadier Battlement, Shield Generator Relay, HMG Emplacement, Anti-Tank Emplacement,
      -- Tesla Tower
        121, 66, 8, 23, 53, 137, 117, 44, 52, 59, 22, 144, 9, 104},
    { -- 7, vehicles and mines: Gunner FRV, Supply FRV, Incinerator FRV, Bastion, Storm tank, Patriot, Emancipator,
      -- Lumberer and Breakthrough Exosuits, Anti-Personnel Minefield, Incendiary Mines, Anti-Tank Mines, Gas Mines
        105, 26, 135, 1, 50, 27, 10, 91, 88, 119, 139, 12, 46},
    { -- 8, mission: Reinforce, Resupply, SOS Beacon, Hellbomb, SEAF Artillery, Super Earth Flag, Upload Data, Seismic
      -- Probe, Prospecting Drill, Illumination Flare, Extraction, SEAF Squad, Nuke
        124, 33, 145, 42, 28, 11, 128, 19, 70, 5, 148, 116, 132},
}
-- The themed tiers keep their banners. Their theme groups get the share of picks vanilla gives its theme group
-- (1.0 of 1.825 in tiers 0-2, 0.6 of 1.425 in tier 3); the rest of each tier is even. Index: tier number.
Mod.THEMES = {
    [0] = {groups = {1}, share = 1 / 1.825},     -- BACK-PACKING A PUNCH: backpacks
    [1] = {groups = {2}, share = 1 / 1.825},     -- FLY LIKE AN EAGLE: eagles
    [2] = {groups = {3}, share = 1 / 1.825},     -- RAIN DOWN FROM ABOVE: orbitals
    [3] = {groups = {4, 5}, share = 0.6 / 1.425}, -- OVERWHELMING FIREPOWER: support weapons
}

-- assert without the file:line prefix: these messages go to the user's log.
local function need(value, message)
    if not value then error(message, 0) end
    return value
end

-- Little-endian u32 and f32 through one-element buffers (x64 is little-endian). Used on the once-per-session
-- path only: u32 makes one substring per call.
local word, float = ffi.new('uint32_t[1]'), ffi.new('float[1]')
local function u32(bytes, offset)
    ffi.copy(word, bytes:sub(offset + 1, offset + 4), 4)
    return word[0]
end

local function le32(value)
    word[0] = value
    return ffi.string(word, 4)
end

local function f32(value)
    float[0] = value
    return ffi.string(float, 4)
end

-- Table encoding ---------------------------------------------------------------------------------------------

-- tiers: {{banner = u32, {group, weight}, ...}, ...} in tier order. 9 x 68 bytes.
function Mod.encode_tiers(tiers)
    need(#tiers == TIERS, 'Expected ' .. TIERS .. ' tiers')
    local parts = {}
    for _, tier in ipairs(tiers) do
        need(#tier >= 1 and #tier <= TIER_ENTRIES, 'A tier lists 1 to ' .. TIER_ENTRIES .. ' groups')
        local record = {le32(tier.banner)}
        for _, entry in ipairs(tier) do
            record[#record + 1] = le32(entry[1]) .. f32(entry[2])
        end
        local bytes = table.concat(record)
        parts[#parts + 1] = bytes .. string.rep('\0', TIER_SIZE - #bytes)
    end
    return table.concat(parts)
end

-- groups: the lists of groups 1-9 (fewer leaves the rest empty); group 0 stays empty. 10 x 64 bytes.
function Mod.encode_groups(groups)
    need(#groups <= GROUPS - 1, 'At most ' .. (GROUPS - 1) .. ' groups')
    local parts = {string.rep('\0', GROUP_SIZE)}
    for index = 1, GROUPS - 1 do
        local group = groups[index] or {}
        need(#group <= GROUP_SLOTS, 'A group holds at most ' .. GROUP_SLOTS .. ' stratagems')
        local record = {}
        for _, stratagem in ipairs(group) do record[#record + 1] = le32(stratagem) end
        local bytes = table.concat(record)
        parts[#parts + 1] = bytes .. string.rep('\0', GROUP_SIZE - #bytes)
    end
    return table.concat(parts)
end

-- One tier's entries: every group weighted by its size, so each stratagem is equally likely, except that a
-- theme's groups (listed first, as in vanilla) together get theme.share of the picks.
local function tier_entries(sizes, total, theme)
    local entries, themed, theme_total = {}, {}, 0
    for _, group in ipairs(theme and theme.groups or {}) do
        themed[group], theme_total = true, theme_total + sizes[group]
    end
    local scale = 1
    if theme then scale = theme.share / (1 - theme.share) * (total - theme_total) / theme_total end
    for _, group in ipairs(theme and theme.groups or {}) do entries[#entries + 1] = {group, sizes[group] * scale} end
    for group = 1, #sizes do
        if not themed[group] then entries[#entries + 1] = {group, sizes[group]} end
    end
    return entries
end

-- The new tiers for groups: the vanilla banners, and Mod.THEMES's shares in the themed tiers.
function Mod.tiers(groups)
    local sizes, total = {}, 0
    for index, group in ipairs(groups) do sizes[index], total = #group, total + #group end
    local tiers = {}
    for tier = 0, TIERS - 1 do
        local entries = tier_entries(sizes, total, Mod.THEMES[tier])
        entries.banner = Mod.VANILLA_TIERS[tier + 1].banner
        tiers[tier + 1] = entries
    end
    return tiers
end

-- {tiers, groups} as bytes: build 25480438's and the mod's.
function Mod.tables()
    return {
        vanilla = {tiers = Mod.encode_tiers(Mod.VANILLA_TIERS), groups = Mod.encode_groups(Mod.VANILLA_GROUPS)},
        expanded = {tiers = Mod.encode_tiers(Mod.tiers(Mod.GROUPS)), groups = Mod.encode_groups(Mod.GROUPS)},
    }
end

-- Checks against the game ------------------------------------------------------------------------------------

-- The StratagemInfo pointer table, or nil while the game has not loaded its stratagem settings (1 read; 2 when
-- they are loaded).
function Mod.stratagem_settings(api, game, layout)
    local probe = api.read(game + layout.settings_rva + 8 * Mod.PROBE, 8)
    if not api.pointer(probe) then return nil end
    return need(api.read(game + layout.settings_rva, TYPES * 8), 'Stratagem settings unreadable')
end

-- Raises unless every stratagem of the pool has settings of its own type, with a code and a HUD colour the
-- arcade can show. A stratagem without settings would crash the arcade's widget, and a data-only game update can
-- change the settings without changing the binaries the build check covers, so this runs every session.
function Mod.check_pool(api, settings, groups)
    for _, group in ipairs(groups) do
        for _, stratagem in ipairs(group) do
            local name = 'stratagem ' .. stratagem
            local info = need(stratagem > 0 and stratagem < TYPES and api.pointer(settings, stratagem * 8),
                'No settings for ' .. name)
            local record = need(api.read(info, INFO_SIZE), 'Settings of ' .. name .. ' unreadable')
            need(u32(record, INFO_TYPE) == stratagem, 'The settings of ' .. name .. ' belong to another stratagem')
            local length = u32(record, INFO_CODE_LENGTH)
            need(length >= 1 and length <= MAX_CODE and api.pointer(record, INFO_CODE),
                'The code of ' .. name .. ' does not fit the arcade')
            need(u32(record, INFO_HUD) <= MAX_HUD, 'Unexpected HUD type for ' .. name)
        end
    end
end

-- Whether [address, address + size) lies in committed image pages of the module at base that can be written;
-- the protections seen. game.dll's data section is module image memory, which Bingus Shared Runtime's checked
-- write refuses by design (api.writable_data accepts private memory only), so the mod checks it here: never
-- code-only, read-only or guard pages, and no protection change.
function Mod.image_writable(api, native, base, address, size)
    local cursor, finish, module = api.address(address), api.address(address) + size, api.address(base)
    local seen = {}
    while cursor < finish do
        local region = native.query(cursor)
        if not region or region.state ~= MEM_COMMIT or region.type ~= MEM_IMAGE
            or region.allocation_base ~= module or not WRITABLE[region.protection] or region.finish <= cursor then
            return false, seen
        end
        seen[#seen + 1] = string.format('0x%02X', region.protection)
        cursor = region.finish
    end
    return true, seen
end

-- The page query and write the mod makes beyond the runtime's reads, bound once: VirtualQuery and
-- WriteProcessMemory under the runtime's private names.
function Mod.native(api)
    local windows = api.windows
    local kernel = windows.kernel32
    local region_type = 'bingus_memory1_region'
    local region, region_size = ffi.new(region_type), ffi.sizeof(region_type)
    local process, done = kernel.GetCurrentProcess(), ffi.new('size_t[1]')
    local HIGH = 4294967296
    local native = {}
    -- {state, type, protection, allocation_base, finish} of the region holding address, or nil.
    function native.query(address)
        if kernel.VirtualQuery(address, region, region_size) ~= region_size then return nil end
        return {state = region.state, type = region.type, protection = region.protection,
                allocation_base = region.allocation_base_low + region.allocation_base_high * HIGH,
                finish = region.base_low + region.base_high * HIGH + region.size_low + region.size_high * HIGH}
    end
    function native.write(address, bytes)
        return kernel.WriteProcessMemory(process, ffi.cast('void *', address), bytes, #bytes, done) ~= 0
    end
    return native
end

-- What the arcade's tables hold: 'vanilla', 'expanded', or nil and why not either. One read of both tables (the
-- 76 bytes between them belong to other code and are never written).
function Mod.arcade_state(api, game, layout, tables)
    local tiers = game + layout.tiers_rva
    local span = layout.groups_rva + GROUPS * GROUP_SIZE - layout.tiers_rva
    local bytes = need(api.read(tiers, span), 'Arcade tables unreadable')
    local current = {tiers = bytes:sub(1, TIERS * TIER_SIZE),
                     groups = bytes:sub(span - GROUPS * GROUP_SIZE + 1)}
    for _, name in ipairs({'vanilla', 'expanded'}) do
        if current.tiers == tables[name].tiers and current.groups == tables[name].groups then return name end
    end
    return nil
end

-- Writes both tables after checking their pages; then reads them back. Returns the page protections seen.
local function write_tables(api, native, game, layout, tables)
    local tiers, groups = game + layout.tiers_rva, game + layout.groups_rva
    local ok, seen = Mod.image_writable(api, native, game, tiers, TIERS * TIER_SIZE)
    local groups_ok, groups_seen = Mod.image_writable(api, native, game, groups, GROUPS * GROUP_SIZE)
    need(ok and groups_ok, 'Arcade tables are not in writable game.dll data pages')
    need(native.write(tiers, tables.expanded.tiers) and native.write(groups, tables.expanded.groups),
        'Arcade table write failed')
    need(Mod.arcade_state(api, game, layout, tables) == 'expanded', 'Arcade table write did not hold')
    for _, protection in ipairs(groups_seen) do seen[#seen + 1] = protection end
    return table.concat(seen, ', ')
end

-- One attempt: 'applied' with the page protections seen, 'already applied', or 'wait' with what the game has not
-- loaded yet. Raises when anything differs from build 25480438's data; nothing is written then.
function Mod.attempt(api, native, game, layout, tables)
    local settings = Mod.stratagem_settings(api, game, layout)
    if not settings then return 'wait', 'the stratagem settings are not loaded yet' end
    Mod.check_pool(api, settings, Mod.GROUPS)
    local state = Mod.arcade_state(api, game, layout, tables)
    if state == 'expanded' then return 'already applied' end
    need(state == 'vanilla', "The arcade's tables differ from build 25480438's")
    return 'applied', write_tables(api, native, game, layout, tables)
end

-- Loader, hooks and log ----------------------------------------------------------------------------------------

-- Runs try(dt) from the update chain until it reports done (or raises), then calls finish(ok, error) and leaves
-- the chain: the previous update comes back if this hook is still the outermost one, otherwise the hook stays as a
-- pass-through. The previous update runs first, outside pcall, so its errors reach the game unchanged.
function Mod.hook(env, try, finish)
    local previous, done, hook = env.update, false, nil
    local function attempt(dt)
        if done then return end
        local ok, result = pcall(try, dt)
        if ok and not result then return end
        done = true
        finish(ok, result)
        if env.update == hook then env.update = previous or function() end end
    end
    local function pass(dt, ...)
        attempt(dt)
        return ...
    end
    hook = function(dt, ...)
        if not previous then return attempt(dt) end
        return pass(dt, previous(dt, ...))
    end
    env.update = hook
end

-- At shutdown, one read logs whether the tables still hold the expanded pool; the previous shutdown runs after,
-- outside pcall.
function Mod.report_at_shutdown(env, api, state, note)
    local previous = env.shutdown
    env.shutdown = function(...)
        pcall(function()
            if not state.applied then return end
            local held = Mod.arcade_state(api, state.game, state.layout, state.tables) == 'expanded'
            note(held and 'At shutdown: the arcade still draws from the expanded pool.'
                or 'At shutdown: the arcade tables no longer hold the expanded pool.')
        end)
        if previous then return previous(...) end
    end
end

local function log_writer(loader)
    local file
    if type(loader) == 'table' and type(loader.open_log) == 'function' then
        pcall(function() file = loader.open_log('StratagemHeroExpanded.log') end)
    end
    return function(line)
        print('[StratagemHeroExpanded] ' .. line)
        if file then pcall(function() file:write(line .. '\n'); file:flush() end) end
    end
end

local function pool_size()
    local count = 0
    for _, group in ipairs(Mod.GROUPS) do count = count + #group end
    return count
end

-- The attempt at load, then the fallback hook while the game has not loaded its stratagem settings.
local function start(env, api, native, state, note)
    local function try_once()
        local result, detail = Mod.attempt(api, native, state.game, state.layout, state.tables)
        if result == 'wait' then
            state.status = 'waiting: ' .. detail
            return false
        end
        state.applied = true
        state.status = result .. ' (' .. pool_size() .. ' stratagems in ' .. #Mod.GROUPS .. ' groups'
            .. (detail and ('; pages ' .. detail) or '') .. ')'
        return true
    end
    if try_once() then return note(state.status .. ', at load.') end
    note('Waiting for the game: ' .. state.status:sub(#'waiting: ' + 1) .. '.')
    local waited = 0
    Mod.hook(env, function(dt)
        if try_once() then return true end
        waited = waited + (tonumber(dt) or 0)
        need(waited < Mod.WAIT_SECONDS, 'gave up after ' .. Mod.WAIT_SECONDS .. ' s: ' .. state.status)
        return false
    end, function(ok, err)
        if not ok then state.status = 'disabled: ' .. tostring(err) end
        note(ok and string.format('%s, after %.1f s.', state.status, waited) or ('Disabled: ' .. tostring(err)))
    end)
end

-- Installs the mod. api: bingus_memory.lua's api extended by bingus_write.lua (for its WriteProcessMemory
-- binding). options: env (the table holding update and shutdown, default _G), layout, loader (default the global
-- Bingus Shared Loader), native (default Mod.native(api); tests pass their own page query).
function Mod.install(api, options)
    options = options or {}
    local env = options.env or _G
    local loader = options.loader or rawget(_G, 'CowboyBingusModLoader')
    local state = {version = Mod.VERSION, status = 'starting', applied = false,
                   layout = options.layout or Mod.LAYOUT}
    env.StratagemHeroExpanded = state
    local note = log_writer(loader)
    local ok, err = pcall(function()
        need(type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function',
            'Bingus Shared Loader with API 1 required')
        local built, why = api.verify_build({exe_sha256 = Mod.EXE_SHA256, game_sha256 = Mod.GAME_SHA256})
        need(built, why == 'unsupported game build' and 'Unsupported game build (needs Steam build 25480438)' or why)
        state.game = need(api.module('game.dll'), 'game.dll not loaded')
        state.tables = Mod.tables()
        start(env, api, options.native or Mod.native(api), state, note)
    end)
    if not ok then
        state.status = 'disabled: ' .. tostring(err)
        note('Stratagem Hero Expanded v' .. Mod.VERSION .. ' disabled: ' .. tostring(err))
        return state
    end
    Mod.report_at_shutdown(env, api, state, note)
    return state
end

return Mod
