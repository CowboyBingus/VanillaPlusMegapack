-- Shallow Water Diving: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. These show in Mod Options Menu, which
-- upper-cases the mod name.
return {
    mod = 'shallow_water_diving',
    title = 'Shallow Water Diving',
    language = 'en',
    strings = {
        -- The mod's name: its category button in Mod Options Menu.
        ['option.mod'] = 'Shallow Water Diving',
        -- The slider's name.
        ['option.depth.label'] = 'Max Dive Water Depth',
        -- Shown beside the slider. 0.20 and 1.30 are the slider's ends, in the game's units.
        ['option.depth.description'] = 'Deepest water, measured up from your feet, that a dive can start in: from 0.20 (lower shin, the original limit) up to 1.30, where your Helldiver starts swimming. Deeper water always keeps the game\'s normal behavior.',
    },
    -- Mod Options Menu's limits, in characters.
    limits = {['option.mod'] = 40, ['option.depth.label'] = 64, ['option.depth.description'] = 400},
}
