-- Ship Station Hotkeys: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. These show on the MODS tab of the game's
-- binding pages (Mod Bindings Menu), which upper-cases them. The Galactic
-- Map, Armory, Ship Management and Hellpod bindings use the game's own names,
-- translated by the game.
return {
    mod = 'ship_station_hotkeys',
    title = 'Ship Station Hotkeys',
    language = 'en',
    strings = {
        -- Section header above the six bindings.
        ['binding.section'] = 'Ship Station Hotkeys',
        -- The ship's Control Center station (opens its menu).
        ['binding.control_center'] = 'CONTROL CENTER',
        -- The Stratagem Hero arcade cabinet (starts it while you stand beside it).
        ['binding.stratagem_hero'] = 'STRATAGEM HERO',
    },
    -- Mod Bindings Menu's limits, in characters.
    limits = {['binding.section'] = 64, ['binding.control_center'] = 127, ['binding.stratagem_hero'] = 127},
}
