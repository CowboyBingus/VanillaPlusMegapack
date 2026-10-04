-- Option categories: which mods get one (the first 112 to register; past 8,
-- the MODS tab's category buttons show them in pages) and their identity.
-- Usage: <lua> tests/test_categories.lua [path to src/mod_options_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_options_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
-- No values file: the folder does not exist, so every option starts at its default.
local directory = assert(os.getenv('TEMP') or os.getenv('TMP')) .. '/mom-categories-test-no-folder'
local Text = dofile(root .. '/src/bingus_text.lua')
_G.mom_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
_G.mom_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})

local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local lines = {}
local function count(text)
    local found = 0
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then found = found + 1 end
    end
    return found
end
-- A new instance without a menu, logging into `lines`.
local function fresh()
    _G.ModOptionsMenu, _G.update, _G.BingusTranslations, _G.BingusRuntime = nil, function() end, nil, nil
    Text.registry().steam_language = 'en'
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function()
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}
    dofile(source)
    local menu = assert(ModOptionsMenu)
    local step = upvalue(update, 'step')
    return menu, upvalue(menu.register_option, 'state'),
           upvalue(upvalue(upvalue(step, 'enter_view'), 'list_mods'), 'mod_list')
end
local function titles(list)
    local names = {}
    for index, mod in ipairs(list) do names[index] = mod.title end
    return table.concat(names, ',')
end
local function toggle(mod, label) return {type = 'toggle', label = label or 'Enabled', mod = mod} end

-- Capacity: the first 112 mods to register are shown (alphabetically; past 8
-- the category buttons show them 7 at a time). A 113th mod is refused with a
-- reason and logged once, even an alphabetically earlier one, so no mod that
-- is shown can be displaced.
do
    local menu, state, mod_list = fresh()
    assert(menu.api == 1 and menu.version == 3 and menu.max_mods == 112 and menu.max_options == 32)
    for _, name in ipairs({'Hotel', 'Bravo', 'Golf', 'Delta', 'Alpha', 'Foxtrot', 'Charlie', 'Echo'}) do
        assert(menu.register_option(name:lower() .. '.enabled', toggle(name)))
    end
    assert(titles(mod_list()) == 'ALPHA,BRAVO,CHARLIE,DELTA,ECHO,FOXTROT,GOLF,HOTEL')
    -- 104 more, registered out of order (37 steps through 1..104).
    for index = 1, 104 do
        local n = index * 37 % 104 + 1
        assert(menu.register_option(string.format('more%03d.enabled', n), toggle(string.format('More %03d', n))))
    end
    local before = #lines
    local ok, reason = menu.register_option('aardvark.enabled', toggle('Aardvark'))
    assert(ok == false and reason == 'all 112 mod categories are in use', 'a 113th mod is refused')
    assert(#lines == before + 1 and lines[#lines]:find('Refused the options of AARDVARK', 1, true))
    ok, reason = menu.register_option('aardvark.extra', toggle('Aardvark', 'Extra'))
    assert(ok == false and reason == 'all 112 mod categories are in use' and #lines == before + 1, 'logged once')
    assert(menu.get('aardvark.enabled') == nil and not state.options['aardvark.enabled'])
    assert(menu.register_option('bravo.extra', toggle('Bravo', 'Extra')), 'a mod that is shown keeps adding options')
    local list = mod_list()
    assert(#list == 112 and list[1].title == 'ALPHA' and list[8].title == 'HOTEL' and list[9].title == 'MORE 001'
           and list[112].title == 'MORE 104', 'all 112 mods, alphabetically')
    -- Each refused mod is logged once, the first 8 of them; the 8th line says
    -- that further ones are not logged.
    for index = 1, 10 do assert(not menu.register_option('late' .. index .. '.enabled', toggle('Late ' .. index))) end
    assert(count('Refused the options of ') == 8 and count('further refused mods are not logged') == 1)
    assert(lines[#lines]:find('Refused the options of LATE 7', 1, true), 'nothing logged after the 8th refusal')
    assert(#state.mods == 112)
end
print('PASS: the first 112 mods to register get a category, shown alphabetically; a 113th mod\'s register_option '
      .. 'returns false and a reason, logged once per refused mod')

-- Registrations from an addon: a chunk named after it calls register_option
-- (not as a tail call, which would hide the chunk's frame).
local function addon(name)
    return assert(loadstring('local ok, why = ModOptionsMenu.register_option(...); return ok, why', name))
end

-- Identity: a mod whose name is a text function keeps one category when the
-- game's language changes (audit reproduction: register, change the language,
-- refresh as when the escape menu opens, register again -> two categories).
do
    local menu, state, mod_list = fresh()
    local translation = upvalue(menu.register_option, 'translation')
    local language = 'en'
    local names = {en = 'Diving', zh = '\229\175\185\230\176\180', de = 'Tauchen'}
    local function spec(label) return {type = 'toggle', label = label, mod = function() return names[language] end} end
    assert(menu.register_option('fn.first', spec('First')))
    language = 'zh'
    translation.refresh()
    assert(#state.mods == 1 and state.mods[1].title == names.zh and state.mods[1].name == 'DIVING')
    assert(menu.register_option('fn.second', spec('Second')))
    assert(#state.mods == 1 and #state.mods[1].order == 2, 'a refresh changes the shown name, not the category')
    -- A registration in a new language before the next refresh finds it too.
    language = 'de'
    assert(menu.register_option('fn.third', spec('Third')))
    assert(#state.mods == 1 and #state.mods[1].order == 3 and state.mods[1].title == names.zh)
    translation.refresh()
    assert(titles(mod_list()) == 'TAUCHEN')
end

-- Two mods with the same name: categories of their own (each with 32 options),
-- a warning, and still one category per mod. An explicit mod_id keys a
-- category whatever its shown name.
do
    local menu, state, mod_list = fresh()
    local warnings = count('Two mod categories are named ')
    local first, second = addon('@mods/author_a/diving'), addon('@mods/author_b/deep_diving')
    for index = 1, 32 do
        assert(first('a.' .. index, toggle('Diving', 'A ' .. index)))
        assert(second('b.' .. index, toggle('Diving', 'B ' .. index)))
    end
    assert(not first('a.33', toggle('Diving', 'A 33')) and not second('b.33', toggle('Diving', 'B 33')))
    assert(#state.mods == 2 and #state.mods[1].order == 32 and #state.mods[2].order == 32)
    assert(titles(mod_list()) == 'DIVING,DIVING' and mod_list()[1] == state.mods[1], 'same names in their order')
    assert(count('Two mod categories are named ') == warnings + 1, 'one warning')
    assert(count('Two mod categories are named DIVING: addon mods/author_b/deep_diving is kept apart from addon '
                 .. 'mods/author_a/diving.') == 1)
    -- mod_id: one category for every registration with that id, shown under
    -- its first name; another id with the same name is another category.
    assert(menu.register_option('c.one', {type = 'toggle', label = 'One', mod = 'Swimming', mod_id = 'author_c.swim'}))
    assert(menu.register_option('c.two', {type = 'toggle', label = 'Two', mod = 'Schwimmen', mod_id = 'author_c.swim'}))
    assert(menu.register_option('c.three', {type = 'toggle', label = 'Three', mod_id = 'author_c.swim'}))
    assert(#state.mods == 3 and #state.mods[3].order == 3 and state.mods[3].title == 'SWIMMING')
    assert(menu.register_option('d.one', {type = 'toggle', label = 'One', mod = 'Swimming', mod_id = 'author_d/swim'}))
    assert(#state.mods == 4 and count("SWIMMING: mod_id 'author_d/swim' is kept apart from mod_id 'author_c.swim'.") == 1)
    -- A registration without the id is another mod, even with the same name.
    assert(menu.register_option('e.one', toggle('Swimming')) and #state.mods == 5)
    assert(count('Two mod categories are named SWIMMING: addon ') == 1 and count('Two mod categories') == warnings + 3)
    for _, bad in ipairs({5, '', 'has space', string.rep('i', 65), 'tab\tid', '\195\169t\195\169'}) do
        local ok, reason = menu.register_option('bad.id', {type = 'toggle', label = 'Bad', mod = 'Bad', mod_id = bad})
        assert(ok == false and reason == 'invalid mod_id', 'invalid mod_id ' .. tostring(bad))
    end
    assert(menu.register_option('f.one', {type = 'toggle', label = 'Max', mod_id = string.rep('i', 64)}))
    -- A mod without a name or an id is named after its addon entry.
    assert(addon('@mods/example/better_hud')('g.one', {type = 'toggle', label = 'Named'}))
    assert(state.mods[7].title == 'BETTER HUD' and state.mods[7].origin == '@mods/example/better_hud')
    -- With every category in use, a different mod is refused even under a name that is shown.
    assert(menu.register_option('h.one', toggle('Last')) and #state.mods == 8)
    for index = 9, 112 do assert(menu.register_option('fill' .. index .. '.one', toggle('Fill ' .. index))) end
    local ok, reason = addon('@mods/author_z/diving')('z.one', toggle('Diving'))
    assert(ok == false and reason == 'all 112 mod categories are in use' and #state.mods == 112)
    assert(menu.register_option('h.two', toggle('Last', 'Two')), 'a mod with a category still registers')
end
print('PASS: categories are keyed by mod_id or by addon and first resolved name: a language refresh changes only '
      .. 'the shown name, two mods with one name keep apart with a warning, and invalid mod_ids are refused')
