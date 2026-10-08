-- Match Your Colors: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. Every text shows in Mod Options Menu, which upper-cases the mod name and
-- the choices. OFF, ON and the toggles' values are the game's own words and are not here.
-- The scheme names are the game's names of its weapon paint schemes.
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
        ['option.mode.description'] = 'Recolors your helmet to your armor\'s colors, or your armor to your helmet\'s. Squadmates who use this mod see your colors too (your settings are shared through the squad\'s online lobby); players without it see your gear as it is. Visors, lenses and lights keep their colors.',
        -- The paint scheme choice: Off / the game's weapon paint schemes below.
        ['option.scheme.label'] = 'Paint Scheme',
        ['option.scheme.description'] = 'Paints your helmet and armor in one of the game\'s weapon paint schemes. While a scheme is chosen, Color Matching and Leave Complete Sets do not apply; Recolor Hoods and Match Materials do. Visors, lenses and lights keep their colors.',
        ['scheme.helldiver'] = 'Helldiver',
        ['scheme.forest'] = 'Forest',
        ['scheme.forest_camo'] = 'Forest Camo',
        ['scheme.arctic'] = 'Arctic',
        ['scheme.arctic_camo'] = 'Arctic Camo',
        ['scheme.desert'] = 'Desert',
        ['scheme.desert_camo'] = 'Desert Camo',
        ['scheme.urban'] = 'Urban',
        ['scheme.urban_camo'] = 'Urban Camo',
        ['scheme.night'] = 'Night',
        ['scheme.venus'] = 'Venus',
        -- The toggles.
        ['option.sets.label'] = 'Leave Complete Sets',
        ['option.sets.description'] = 'Keeps the original colors while your helmet and armor belong to the same set.',
        ['option.hoods.label'] = 'Recolor Hoods',
        ['option.hoods.description'] = 'Recolors hoods too, such as those of the RS-100 Sanctioner and SC-30 Trailblazer Scout helmets. Off: a hood keeps its own color, like the visor, while the rest of the helmet still matches.',
        ['option.materials.label'] = 'Match Materials',
        ['option.materials.description'] = 'Metal parts that take a painted color become that paint, so a chrome or gold helmet with a white or green armor turns white or green instead of bronze. Small metal details and cloth keep their material.',
        ['option.capes.label'] = 'Recolor Cape',
        ['option.capes.description'] = 'Recolors your cape too, to the same colors: the armor\'s with Helmet Matches Armor, the helmet\'s with Armor Matches Helmet, or the paint scheme\'s. A complete set left alone still gives its cape its colors. Emblems and other decals keep their colors.',
    },
    -- Mod Options Menu's limits, in characters.
    limits = {
        ['option.mod'] = 40, ['option.mode.label'] = 64, ['option.mode.helmet'] = 48, ['option.mode.armor'] = 48,
        ['option.mode.description'] = 400, ['option.sets.label'] = 64, ['option.sets.description'] = 400,
        ['option.hoods.label'] = 64, ['option.hoods.description'] = 400, ['option.materials.label'] = 64,
        ['option.materials.description'] = 400, ['option.scheme.label'] = 64, ['option.scheme.description'] = 400,
        ['scheme.helldiver'] = 48, ['scheme.forest'] = 48, ['scheme.forest_camo'] = 48, ['scheme.arctic'] = 48,
        ['scheme.arctic_camo'] = 48, ['scheme.desert'] = 48, ['scheme.desert_camo'] = 48, ['scheme.urban'] = 48,
        ['scheme.urban_camo'] = 48, ['scheme.night'] = 48, ['scheme.venus'] = 48, ['option.capes.label'] = 64,
        ['option.capes.description'] = 400,
    },
}
