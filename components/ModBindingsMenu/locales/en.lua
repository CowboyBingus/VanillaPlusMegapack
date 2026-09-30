-- Mod Bindings Menu: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. Binding names and section names come from
-- the mods that register them and are translated with those mods.
return {
    mod = 'mod_bindings_menu',
    title = 'Mod Bindings Menu',
    language = 'en',
    strings = {
        -- The fourth tab of the key and controller binding pages, after the game's own
        -- three. Upper case like theirs, and about as short.
        ['tab.mods'] = 'MODS',
        -- The only row of the MODS tab when no mod has registered a binding.
        ['section.none'] = 'NO MOD BINDINGS INSTALLED',
        -- Section name for bindings of a mod that gave no name.
        ['section.unnamed'] = 'MODS',
    },
    -- Rough room in ems (the tool warns when a translation looks wider).
    widths = {['tab.mods'] = 8},
}
