-- locales/en.lua: every text key the code uses exists, every English text is used, and the Mod Options Menu
-- texts keep within the menu's limits. Usage: test_locales.lua <repository root>
local root = assert(arg[1], 'repository root required')
local Text = dofile(root .. '/src/bingus_text.lua')
local english = dofile(root .. '/locales/en.lua')
assert(english.mod == 'match_your_colors' and english.language == 'en')
rawset(_G, 'BingusTranslations', nil)
Text.registry().game_language = 'en'
Text.new(english) -- asserts every English text is valid and within its limit
local file = assert(io.open(root .. '/src/addon.lua', 'rb'))
local code = file:read('*a')
file:close()
local used = 0
for key in code:gmatch("'(option%.[%l_.]+)'") do
    assert(english.strings[key], 'the code uses a text missing from en.lua: ' .. key)
    used = used + 1
end
for key in pairs(english.strings) do
    assert(code:find("'" .. key .. "'", 1, true), 'unused text in en.lua: ' .. key)
end
local MENU = {['option.mod'] = 40, ['option.mode.label'] = 64, ['option.mode.helmet'] = 48,
              ['option.mode.armor'] = 48, ['option.mode.description'] = 400, ['option.sets.label'] = 64,
              ['option.sets.description'] = 400}
for key, limit in pairs(MENU) do
    assert(english.limits[key] == limit, 'limit of ' .. key)
    assert(#english.strings[key] <= limit, key .. ' over the menu\'s byte limit')
end
print('PASS test_locales (en.lua holds every text the code shows, ' .. used .. ' uses, within Mod Options Menu limits)')
