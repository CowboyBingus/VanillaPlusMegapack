-- Match Your Colors: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. Every text shows in Mod Options Menu, which upper-cases the mod name and
-- the choices. OFF, ON and the toggle's values are the game's own words and are not here.
return {
    mod = 'match_your_colors',
    title = 'Match Your Colors',
    language = 'en',
    strings = {
        -- The mod's category button in the MODS tab.
        ['option.mod'] = 'Match Your Colors',
        -- The choice: Off / the two directions below.
        ['option.mode.label'] = 'Color Matching',
        ['option.mode.helmet'] = 'Helmet Matches Armor',
        ['option.mode.armor'] = 'Armor Matches Helmet',
        ['option.mode.description'] = 'Recolors your helmet to your armor\'s colors, or your armor to your helmet\'s. Only your own Helldiver changes, and only on your screen. Visors, lenses and lights keep their colors.',
        -- The toggle.
        ['option.sets.label'] = 'Leave Complete Sets',
        ['option.sets.description'] = 'Keeps the original colors while your helmet and armor belong to the same set.',
    },
    -- Mod Options Menu's limits, in characters.
    limits = {
        ['option.mod'] = 40, ['option.mode.label'] = 64, ['option.mode.helmet'] = 48, ['option.mode.armor'] = 48,
        ['option.mode.description'] = 400, ['option.sets.label'] = 64, ['option.sets.description'] = 400,
    },
}
