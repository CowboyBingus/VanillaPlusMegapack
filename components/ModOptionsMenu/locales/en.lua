-- Mod Options Menu: English texts, the source of every translation.
-- Translators: see TRANSLATING.md. Option names, descriptions and choices come
-- from the mods that register them and are translated with those mods.
return {
    mod = 'mod_options_menu',
    title = 'Mod Options Menu',
    language = 'en',
    strings = {
        -- The fourth tab of the escape menu, after the game's GAME, SOCIAL and OPTIONS.
        -- Upper case like theirs, and about as short.
        ['tab.mods'] = 'MODS',
        -- The first category button of the MODS tab when no mod has registered options.
        ['category.none'] = 'NO MOD OPTIONS INSTALLED',
        -- Category name for a mod that registered options without giving its name.
        ['mod.unnamed'] = 'MODS',
        -- The last category button when more than 8 mods have options: the
        -- buttons then show 7 mods at a time, and this one opens the page row
        -- below. {page} and {pages} are numbers. Upper case like the buttons.
        ['category.page'] = 'PAGE {page} OF {pages}',
        -- That button's only row: its name, its value for each page ({page}
        -- and {pages} are numbers) and its description.
        ['page.label'] = 'Mods Page',
        ['page.value'] = '{page} / {pages}',
        ['page.description'] = 'The category buttons show 7 mods at a time. Change the page to see the others.',
    },
    -- Rough room in ems (the tool warns when a translation looks wider).
    widths = {['tab.mods'] = 8, ['category.none'] = 20, ['category.page'] = 20},
}
