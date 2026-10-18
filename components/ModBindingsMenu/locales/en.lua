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
        -- The fifth tab, shown only when mods registered more bindings than the
        -- MODS tab can hold. Upper case and short, like the other tabs.
        ['tab.more'] = 'MORE MODS',
        -- The heading at the top of the MORE MODS tab.
        ['section.more'] = 'MORE MOD BINDINGS',
        -- In place of the keys of a binding that has none on this page.
        ['binding.none'] = 'NOT BOUND',
        -- In place of the keys while the player chooses new ones on the keyboard page.
        ['binding.capture'] = 'PRESS A KEY',
        -- In place of the binding's name meanwhile: the keys that cancel and clear.
        ['binding.capture_hint'] = 'ESC: CANCEL, DELETE: CLEAR',
        -- The same two on the controller page.
        ['binding.capture_pad'] = 'PRESS A BUTTON',
        ['binding.capture_hint_pad'] = 'B: CANCEL, X: CLEAR',
        -- In place of the keys of a binding saved by a newer Mod Bindings Menu,
        -- which this version leaves untouched.
        ['binding.inactive'] = 'SAVED BY A NEWER VERSION',
    },
    -- Rough room in ems (the tool warns when a translation looks wider).
    widths = {['tab.mods'] = 8, ['tab.more'] = 12},
}
