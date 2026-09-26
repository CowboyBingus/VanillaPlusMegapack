-- Bundle identity only. Bingus Shared Loader starts the gameplay resources
-- through its registry or declared entry discovery, exactly once.
-- Do not require them here: that would duplicate startup and failure handling.
local loader = assert(rawget(_G, 'CowboyBingusModLoader'), 'Bingus Shared Loader is required')
assert(type(loader.api) == 'number' and loader.api >= 1, 'Shared loader API 1 is required')
assert(type(loader.version) == 'number' and loader.version >= 16, 'Bingus Shared Loader loader-v16 is required')
local pack = {
    name = 'Vanilla Plus Megapack',
    revision = 'megapack-v31',
    -- Available component inventory; installed choices are in loader.modules.
    modules = {
        'mods/cowboybingus/better_stratagem_bounce',
        'mods/cowboybingus/hellpod_steering_unlocked',
        'mods/cowboybingus/reinforcement_beacon_fix_data',
        'mods/cowboybingus/consistent_vaulting',
        'mods/cowboybingus/shallow_water_dive',
        'mods/cowboybingus/sentry_aim_retention',
        'mods/cowboybingus/corpse_collision_repair',
        'mods/cowboybingus/hover_pack_cancel',
        'mods/cowboybingus/enemy_intelligence',
        'mods/cowboybingus/armory_preview_cache',
        'mods/cowboybingus/clickable_scrollbars',
        'mods/cowboybingus/arc_thrower_auto',
        'mods/cowboybingus/galactic_menu_hotkey',
    },
}
loader.megapack = pack

-- The game's LuaJIT keeps its 2015 code cache limits (512 KB of machine code,
-- 1000 traces) for the game and every mod; filling either discards every
-- compiled trace. Bingus Shared Loader v18 and newer manage the cache and set
-- loader.jit. With an older loader, or if the loader could not manage it,
-- raise the limits once to the loader's starting values: no watcher, no
-- per-frame work.
if not (type(loader.jit) == 'table' and loader.jit.managed) then
    local library = rawget(_G, 'jit')
    local opt = type(library) == 'table' and type(library.opt) == 'table' and library.opt.start
    if type(opt) == 'function' and pcall(opt, 'maxmcode=16384', 'maxtrace=8000') then
        pack.jit_fallback = 'maxmcode=16384 maxtrace=8000'
    end
end
return pack
