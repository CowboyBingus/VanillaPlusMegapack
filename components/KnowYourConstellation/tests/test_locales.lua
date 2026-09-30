-- locales/en.lua holds every text the panel shows: each constellation title,
-- each roster enemy under its exact roster_data.lua name, the captions, and
-- nothing unused. Bundled translations are checked by scripts/build.py
-- (translations.py check): data only, no refused entry.
local source = assert(arg[1])
local T = assert(loadfile(source .. '/bingus_text.lua'))()
local model = assert(loadfile(source .. '/model.lua'))()
local data = assert(loadfile(source .. '/roster_data.lua'))()
local english = assert(loadfile(source .. '/../locales/en.lua'))()
assert(english.mod == 'know_your_constellation' and english.language == 'en')

local used = {}
for _, key in ipairs({'panel.label', 'panel.footer', 'panel.large', 'panel.rate', 'panel.small', 'panel.order',
                      'panel.more', 'panel.list_separator', 'headline.separator', 'headline.standard'}) do
    assert(english.strings[key], 'en.lua lacks ' .. key)
    used[key] = true
end
for id = 1, 31 do
    local key = assert(model.TITLES[id], 'Missing title key for tag ' .. id)
    assert(english.strings[key], 'en.lua lacks ' .. key)
    used[key] = true
end
for _, entry in ipairs(data.names) do
    local key = model.unit_key(entry[1])
    assert(english.strings[key] == entry[1], 'en.lua must name ' .. entry[1] .. ' as roster_data.lua does (' .. key .. ')')
    assert(not used[key], 'Two enemies share the key ' .. key)
    used[key] = true
end
for key in pairs(english.strings) do assert(used[key], 'Unused text in en.lua: ' .. key) end
assert(model.unit_key('MG Raiders') == 'unit.mg_raiders' and model.unit_key('Hulk Scorchers') == 'unit.hulk_scorchers')

-- The translator accepts the English file (it asserts every text is valid)
-- and fills placeholders.
T.registry().game_language = 'en'
local tr = T.new(english)
assert(tr('panel.more', {count = 2}) == 'and 2 more')
print('PASS: en.lua names every title and roster enemy exactly, with no unused text')
