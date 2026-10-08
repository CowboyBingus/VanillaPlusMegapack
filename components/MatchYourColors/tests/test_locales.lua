-- locales/en.lua: every text key the code uses exists, every English text is used, and the Mod Options Menu
-- texts keep within the menu's limits. Usage: test_locales.lua <repository root>
local root = assert(arg[1], 'repository root required')
local Text = dofile(root .. '/src/bingus_text.lua')
local english = dofile(root .. '/locales/en.lua')
assert(english.mod == 'match_your_colors' and english.language == 'en')
rawset(_G, 'BingusTranslations', nil)
Text.registry().game_language = 'en'
Text.new(english) -- asserts every English text is valid and within its limit
-- The code that shows texts: the options (src/addon.lua) and the paint scheme names (src/schemes.lua).
local code = ''
for _, name in ipairs({'addon.lua', 'schemes.lua'}) do
    local file = assert(io.open(root .. '/src/' .. name, 'rb'))
    code = code .. file:read('*a') .. '\n'
    file:close()
end
local used = 0
for _, pattern in ipairs({"'(option%.[%l_.]+)'", "'(scheme%.[%l_]+)'"}) do
    for key in code:gmatch(pattern) do
        assert(english.strings[key], 'the code uses a text missing from en.lua: ' .. key)
        used = used + 1
    end
end
for key in pairs(english.strings) do
    assert(code:find("'" .. key .. "'", 1, true), 'unused text in en.lua: ' .. key)
end
local MENU = {['option.mod'] = 40, ['option.mode.label'] = 64, ['option.mode.helmet'] = 48,
              ['option.mode.armor'] = 48, ['option.mode.description'] = 400, ['option.sets.label'] = 64,
              ['option.sets.description'] = 400, ['option.hoods.label'] = 64, ['option.hoods.description'] = 400,
              ['option.materials.label'] = 64, ['option.materials.description'] = 400,
              ['option.scheme.label'] = 64, ['option.scheme.description'] = 400,
              ['option.capes.label'] = 64, ['option.capes.description'] = 400}
for _, scheme in ipairs(dofile(root .. '/src/schemes.lua').LIST) do MENU[scheme.text] = 48 end -- choices
local menu_texts = 0
for key, limit in pairs(MENU) do
    assert(english.limits[key] == limit, 'limit of ' .. key)
    assert(#english.strings[key] <= limit, key .. ' over the menu\'s byte limit')
    menu_texts = menu_texts + 1
end
for key in pairs(english.strings) do assert(MENU[key], 'no Mod Options Menu limit checked for ' .. key) end
print('PASS test_locales (en.lua holds every text the code shows, ' .. used .. ' uses, ' .. menu_texts
      .. ' texts within Mod Options Menu limits)')
