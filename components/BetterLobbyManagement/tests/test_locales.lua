-- locales/en.lua: every text key the code uses exists, every English text is
-- used, and the Mod Options Menu texts keep within the menu's limits.
-- Bundled translations are checked by scripts/build.py (translations.py check).
-- Usage: test_locales.lua <src directory>
local source = assert(arg[1], 'source directory required')
local Text = dofile(source .. '/bingus_text.lua')
local english = dofile(source .. '/../locales/en.lua')
assert(english.mod == 'better_lobby_management' and english.language == 'en')
rawset(_G, 'BingusTranslations', nil)
Text.registry().game_language = 'en'
Text.new(english) -- asserts every English text is valid and within its limit

local code = {}
for _, name in ipairs({'addon.lua', 'lobby.lua', 'sos.lua'}) do
    local file = assert(io.open(source .. '/' .. name, 'rb'))
    code[#code + 1] = file:read('*a')
    file:close()
end
code = table.concat(code, '\n')
local FAMILIES = {button = true, dialog = true, privacy = true, player = true, chat = true, option = true}
local used = 0
for key in code:gmatch("'([%l_]+%.[%l_.]+)'") do
    if FAMILIES[key:match('^[%l_]+')] then
        assert(english.strings[key], 'the code uses a text missing from en.lua: ' .. key)
        used = used + 1
    end
end
for key in pairs(english.strings) do
    assert(code:find("'" .. key .. "'", 1, true), 'unused text in en.lua: ' .. key)
end
-- Mod Options Menu's own limits (characters since v1.1, bytes in v1.0; English fits both).
for key, limit in pairs({['option.mod'] = 40, ['option.region.label'] = 64, ['option.region.default'] = 48,
                         ['option.region.continent'] = 48, ['option.region.description'] = 400}) do
    assert(english.limits[key] == limit, 'limit of ' .. key)
    assert(#english.strings[key] <= limit, key .. ' over the menu\'s byte limit')
end
print('PASS: en.lua holds every text the code shows (' .. used .. ' uses), nothing unused, within Mod Options Menu limits')
