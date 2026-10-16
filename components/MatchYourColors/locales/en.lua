-- Match Your Colors: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. Every text shows in Mod Options Menu, which upper-cases the mod name and
-- the choices. OFF, ON and the toggles' values are the game's own words and are not here.
-- The scheme names are the game's names of its weapon paint schemes; SEAF is the game's name of its troopers.
return {
    mod = 'match_your_colors',
    title = 'Match Your Colors',
    language = 'en',
    strings = {
        -- The mod's category button in the MODS tab.
        ['option.mod'] = 'Match Your Colors',
        -- The choice: Off / the three below.
        ['option.mode.label'] = 'Color Matching',
        ['option.mode.helmet'] = 'Helmet Matches Armor',
        ['option.mode.armor'] = 'Armor Matches Helmet',
        ['option.mode.cape'] = 'Helmet and Armor Match Cape',
        ['option.mode.description'] = 'Recolors your helmet to your armor\'s colors, your armor to your helmet\'s, or both to your cape\'s. Squadmates who use this mod see your colors too (your settings are shared through the squad\'s online lobby); players without it see your gear as it is. Visors, lenses and lights keep their colors.',
        -- The paint scheme choice: Off / the game's weapon paint schemes below.
        ['option.scheme.label'] = 'Paint Scheme',
        ['option.scheme.description'] = 'Paints your helmet and armor in one of the game\'s weapon paint schemes, or in the SEAF troopers\' colors. While a scheme is chosen, Color Matching and Leave Complete Sets do not apply; Recolor Hoods and Match Materials do. Visors, lenses and lights keep their colors.',
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
        -- The SEAF troopers' colors (Super Earth Armed Forces): their blue plates, light uniform and dark gear.
        ['scheme.seaf'] = 'SEAF',
        -- The toggles.
        ['option.sets.label'] = 'Leave Complete Sets',
        ['option.sets.description'] = 'Keeps the original colors while your helmet and armor belong to the same set.',
        ['option.hoods.label'] = 'Recolor Hoods',
        ['option.hoods.description'] = 'Recolors hoods too, such as those of the RS-100 Sanctioner and SC-30 Trailblazer Scout helmets. Off: a hood keeps its own color, like the visor, while the rest of the helmet still matches.',
        ['option.materials.label'] = 'Match Materials',
        ['option.materials.description'] = 'Parts take the material of the color they take: metal parts that take a painted color become that paint (a chrome helmet with a white armor turns white, not bronze), and hard painted parts that take a helmet\'s or armor\'s bare metal become that metal (chrome, gold, cobalt). Cloth and small metal details keep their material.',
        ['option.capes.label'] = 'Recolor Cape',
        -- The choice: Off / the two below. Only this player sees it.
        ['option.squad.label'] = 'Recolor Squadmates',
        ['option.squad.missing'] = 'Squadmates Without the Mod',
        ['option.squad.everyone'] = 'Everyone',
        ['option.squad.description'] = 'Recolors your squadmates\' helmets and armor with your settings, on your screen only. Squadmates Without the Mod: players who use this mod keep the colors they chose. Everyone: every squadmate takes your settings. Nothing changes for them: only you see it.',
        -- The choice: the two below. Only this player sees it.
        ['option.squad_colors.label'] = 'Squadmates\' Colors',
        ['option.squad_colors.own'] = 'Their Own Gear',
        ['option.squad_colors.yours'] = 'Your Colors',
        ['option.squad_colors.description'] = 'For the squadmates Recolor Squadmates recolors. Their Own Gear: your Color Matching on their own gear (their armor matches their own helmet, for example), so a matching set barely changes. Your Colors: their helmet and armor take your colors, those of the item your Color Matching matches (your armor, helmet or cape); a paint scheme gives everyone the scheme. Only you see it.',
        -- The choice: Off / the two below. Your Cape is also shown to squadmates who use this mod.
        ['option.hide_cape.label'] = 'Hide Cape',
        ['option.hide_cape.yours'] = 'Your Cape',
        ['option.hide_cape.everyone'] = 'Everyone\'s Capes',
        ['option.hide_cape.description'] = 'Hides capes on the ship and in missions. Your Cape: yours, also on the screens of squadmates who use this mod. Everyone\'s Capes: yours and every squadmate\'s, on your screen. The Armory and the loadout screen still show capes, so you can still pick one. Players without this mod still see your cape.',
        ['option.capes.description'] = 'Recolors your cape too, to the same colors: the armor\'s with Helmet Matches Armor, the helmet\'s with Armor Matches Helmet, or the paint scheme\'s. A complete set left alone still gives its cape its colors. With Helmet and Armor Match Cape the cape keeps its colors (it is the one matched). Emblems and other decals keep their colors.',
        ['option.weapons.label'] = 'Recolor Weapons',
        ['option.weapons.description'] = 'Recolors your weapons too (primary, sidearm, support weapon and their attachments), to the same colors as the cape: the armor\'s, the helmet\'s, the cape\'s or the paint scheme\'s. While on, it replaces a weapon\'s own paint scheme. Lenses, lights and decals keep their colors; grenades and backpacks keep theirs.',
    },
    -- Mod Options Menu's limits, in characters.
    limits = {
        ['option.mod'] = 40, ['option.mode.label'] = 64, ['option.mode.helmet'] = 48, ['option.mode.armor'] = 48,
        ['option.mode.cape'] = 48, ['option.mode.description'] = 400, ['option.sets.label'] = 64, ['option.sets.description'] = 400,
        ['option.hoods.label'] = 64, ['option.hoods.description'] = 400, ['option.materials.label'] = 64,
        ['option.materials.description'] = 400, ['option.scheme.label'] = 64, ['option.scheme.description'] = 400,
        ['scheme.helldiver'] = 48, ['scheme.forest'] = 48, ['scheme.forest_camo'] = 48, ['scheme.arctic'] = 48,
        ['scheme.arctic_camo'] = 48, ['scheme.desert'] = 48, ['scheme.desert_camo'] = 48, ['scheme.urban'] = 48,
        ['scheme.urban_camo'] = 48, ['scheme.night'] = 48, ['scheme.venus'] = 48, ['scheme.seaf'] = 48, ['option.capes.label'] = 64,
        ['option.capes.description'] = 400, ['option.squad.label'] = 64, ['option.squad.missing'] = 48,
        ['option.squad.everyone'] = 48, ['option.squad.description'] = 400, ['option.squad_colors.label'] = 64,
        ['option.squad_colors.own'] = 48, ['option.squad_colors.yours'] = 48, ['option.squad_colors.description'] = 400,
        ['option.weapons.label'] = 64,
        ['option.weapons.description'] = 400, ['option.hide_cape.label'] = 64, ['option.hide_cape.yours'] = 48,
        ['option.hide_cape.everyone'] = 48, ['option.hide_cape.description'] = 400,
    },
}
