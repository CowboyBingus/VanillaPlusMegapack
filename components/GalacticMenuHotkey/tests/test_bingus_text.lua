-- Tests for bingus_text.lua. Usage: luajit test_bingus_text.lua <folder with bingus_text.lua>
-- Runs in the workspace LuaJIT and in the game's lua51.dll (PerformanceBaseline/game_lua.py).
local folder = arg and arg[1] or '.'
local path = folder .. '/bingus_text.lua'
local function fresh()
    rawset(_G, 'BingusTranslations', nil)
    return dofile(path)
end
local T = fresh()

local function hex(text) return (text:gsub('.', function(c) return string.format('%02X ', c:byte()) end)) end
local function valid(text) return T.check(text) ~= nil end

-- UTF-8 decoding: every well-formed length, and the malformed cases RFC 3629 forbids.
for _, case in ipairs({{'A', 0x41, 2}, {'\195\169', 0xE9, 3}, {'\228\184\173', 0x4E2D, 4},
                       {'\240\159\152\128', 0x1F600, 5}, {'\244\143\191\191', 0x10FFFF, 5}}) do
    local value, after = T.decode(case[1], 1)
    assert(value == case[2] and after == case[3], 'decode ' .. hex(case[1]))
    assert(T.encode(case[2]) == case[1], 'encode ' .. hex(case[1]))
end
for _, bad in ipairs({'\128', '\191', '\192\128', '\193\191', '\224\128\128', '\237\160\128', '\240\128\128\128',
                      '\244\144\128\128', '\245\128\128\128', '\255', '\228\184', '\228', '\195'}) do
    assert(T.decode(bad, 1) == nil, 'must reject ' .. hex(bad))
    assert(not valid('ok ' .. bad), 'check must reject ' .. hex(bad))
end
print('PASS: UTF-8 decoding accepts every well-formed length and rejects overlong, surrogate, truncated and out-of-range bytes')

-- What may be shown: any script, no control characters; a line feed only where allowed.
assert(valid('FORECAST // INTEL AND RECON') and valid('\233\162\132\230\138\165 // \230\131\133\230\138\165'))
assert(valid('Semicolons; are fine now'), 'The old semicolon ban had no reason in the renderer')
for _, bad in ipairs({'tab\tstop', 'bell\7', 'nul\0', 'del\127', 'c1 \194\133 next line'}) do
    assert(not valid(bad), 'control characters are never shown: ' .. hex(bad))
end
assert(not valid('two\nlines') and T.check('two\nlines', true), 'line feeds only in multiline texts')
assert(not pcall(T.display, 'x\1') and T.display('x') == 'x')
assert(not valid(nil) and not valid(5))
print('PASS: display text is any valid UTF-8 without control characters; line feeds only where a text allows them')

-- Lengths and byte caps never split a character.
local zhong = '\228\184\173' -- U+4E2D
assert(T.length('abc') == 3 and T.length(zhong .. zhong .. 'a') == 3 and T.length('') == 0)
local mixed = 'ab' .. zhong .. 'c' .. zhong
for cap = 0, #mixed + 2 do
    local clipped = T.clip(mixed, cap)
    assert(#clipped <= cap and valid(clipped), 'clip ' .. cap)
    assert(mixed:sub(1, #clipped) == clipped)
    -- The longest valid prefix: one more character would not fit.
    local next_char = T.boundaries(mixed)
    for _, edge in ipairs(next_char) do
        if edge - 1 <= cap then assert(#clipped >= edge - 1, 'clip must keep every whole character') end
    end
end
print('PASS: byte caps (the game\'s fixed text buffers) cut only between characters and keep every whole character')

-- Character boundaries keep combining marks and joined emoji with their base.
local e_acute = 'e\204\129' -- e + U+0301
local family = '\240\159\145\168\226\128\141\240\159\145\169' -- man ZWJ woman
local edges = T.boundaries('a' .. e_acute .. family .. zhong)
assert(#edges == 5 and edges[1] == 1 and edges[2] == 2 and edges[3] == 5 and edges[4] == 16 and edges[5] == 19,
    'boundaries: ' .. table.concat(edges, ','))
print('PASS: character boundaries keep combining marks and ZWJ sequences whole')

-- Width model for layout tests: CJK (3-byte) characters 20 units, others 10.
local function measure(text)
    local width, i = 0, 1
    while i <= #text do
        local value, after = T.decode(text, i)
        width = width + ((value >= 0x2E80) and 20 or 10)
        i = after
    end
    return width
end
local function joined(lines) return table.concat(lines) end
local function without_spaces(text) return (text:gsub(' ', '')) end

-- Latin text breaks at spaces only.
local lines = T.wrap('SMALL AND MEDIUM ENEMIES', 100, measure)
assert(#lines == 3 and lines[1] == 'SMALL AND' and lines[2] == 'MEDIUM' and lines[3] == 'ENEMIES', table.concat(lines, '|'))
-- A word wider than the line breaks between characters, nothing lost.
lines = T.wrap(string.rep('W', 80), 40, function(v) return #v * 10 end)
assert(#lines == 20 and joined(lines) == string.rep('W', 80))
assert(not pcall(T.wrap, 'x', 0, function() return 1 end), 'a character wider than the column is an error')

-- Chinese has no spaces: lines break between characters.
local names = {'\230\139\190\232\141\146\232\128\133', '\232\131\134\230\177\129\229\150\183\229\144\144\232\128\133',
    '\229\134\178\233\148\139\232\128\133', '\229\183\168\229\158\139\232\131\134\230\177\129\230\131\138\233\173\130'}
local comma = '\227\128\129' -- U+3001 ideographic comma
local list = table.concat(names, comma)
lines = T.wrap(list, 100, measure)
assert(#lines > 1, 'CJK text must wrap')
for _, line in ipairs(lines) do
    assert(valid(line), 'every line is valid UTF-8: ' .. hex(line))
    assert(measure(line) <= 100, 'every line fits')
    assert(line:sub(1, #comma) ~= comma, 'no line starts with closing punctuation')
end
assert(joined(lines) == list, 'nothing is lost or added')
-- Opening punctuation stays with what follows it.
local open = '\227\128\140' -- U+300C
lines = T.wrap(names[1] .. names[2] .. open .. names[3] .. '\227\128\141', 140, measure)
for _, line in ipairs(lines) do assert(line:sub(-#open) ~= open, 'no line ends with opening punctuation') end
-- Latin punctuation after CJK does not start a line either.
lines = T.wrap(names[1] .. names[1] .. names[1] .. '.', 60, measure)
for _, line in ipairs(lines) do assert(line:sub(1, 1) ~= '.', 'no line starts with a period') end
print('PASS: CJK wraps between characters, never before closing or after opening punctuation, nothing lost')

-- Explicit line feeds (multiline texts) always break; two make an empty line.
lines = T.wrap('one two\nthree\n\nfour', 1000, measure)
assert(#lines == 4 and lines[1] == 'one two' and lines[2] == 'three' and lines[3] == '' and lines[4] == 'four',
    table.concat(lines, '|'))

-- Property check over random mixed text: fits, valid, nothing lost but break spaces.
math.randomseed(7)
local alphabet = {'a', 'b', 'W', ' ', ',', '.', '(', ')', zhong, comma, open, '\227\128\141', e_acute, family,
    '\227\131\188', '\227\129\163'}
for _ = 1, 400 do
    local parts = {}
    for k = 1, math.random(1, 40) do parts[k] = alphabet[math.random(#alphabet)] end
    local text = table.concat(parts)
    local width = math.random(6, 14) * 10 -- wider than the widest single character (the emoji family, 50)
    local ok, result = pcall(T.wrap, text, width, measure)
    assert(ok, tostring(result))
    for _, line in ipairs(result) do
        assert(valid(line), 'invalid line ' .. hex(line))
        assert(measure(line) <= width, 'line wider than the column')
        assert(line:sub(1, 1) ~= ' ' and line:sub(-1) ~= ' ', 'no spaces at line ends')
    end
    assert(without_spaces(joined(result)) == without_spaces(text), 'text lost: ' .. hex(text))
end
print('PASS: 400 random mixed-script texts wrap into valid, fitting lines without losing characters')

-- Placeholders.
assert(T.format('and {count} more', {count = 3}) == 'and 3 more')
assert(T.format('{a}{b}{a}', {a = 1}) == '1{b}1', 'unknown placeholders stay')
assert(T.placeholders('{b} x {a}') == 'a,b' and T.placeholders('none') == '')

-- Pseudo-translation: longer, bracketed, accented, placeholders intact, valid UTF-8.
local pseudo = T.pseudo('and {count} more')
assert(pseudo:sub(1, 1) == '[' and pseudo:sub(-1) == ']' and pseudo:find('{count}', 1, true), pseudo)
assert(valid(pseudo) and T.length(pseudo) > T.length('and {count} more') and pseudo:find('\195\161', 1, true))
print('PASS: placeholders fill by name; pseudo text is longer, accented and keeps placeholders')

-- Translators. English source as in a mod's locales/en.lua.
local english = {mod = 'know_your_constellation', language = 'en', strings = {
    ['panel.label'] = 'FORECAST // INTEL AND RECON',
    ['panel.more'] = 'and {count} more',
    ['option.description'] = 'Short description.',
    ['panel.footer'] = 'Possible encounters.',
}, limits = {['option.description'] = 20}}
local zh = {language = 'zh-Hans', strings = {
    ['panel.label'] = '\233\162\132\230\138\165',
    ['panel.more'] = '\229\143\166\230\156\137 {count} \231\167\141',
}}
local logs = {}
local function logger(message) logs[#logs + 1] = message end

T = fresh()
T.registry().game_language = 'en'
local tr = T.new(english, {['zh-Hans'] = zh}, logger)
assert(tr('panel.label') == 'FORECAST // INTEL AND RECON' and tr('panel.more', {count = 2}) == 'and 2 more')
assert(not pcall(tr.text, tr, 'panel.missing'), 'unknown keys are an error in the mod')
assert(not tr:refresh(), 'nothing changed')

-- The game's language picks the bundled translation; missing keys stay English.
T = fresh()
T.registry().game_language = 'zh-Hans'
tr = T.new(english, {['zh-Hans'] = zh}, logger)
assert(tr('panel.label') == zh.strings['panel.label'] and tr('panel.more', {count = 4}):find('4', 1, true))
assert(tr('panel.footer') == 'Possible encounters.')
assert(logs[#logs]:find('2 of 4 texts translated', 1, true), logs[#logs])

-- A pack registered later wins over the bundled text, from the next lookup
-- on; tr.generation tells a mod that cached texts to rebuild.
local serial, generation = T.registry().serial, tr.generation
T.register({language = 'zh-Hans', name = 'community', mods = {
    know_your_constellation = {['panel.label'] = 'PACK', ['panel.footer'] = 'FOOTER'},
    mod_options_menu = {['anything'] = 'ignored here'},
}})
assert(T.registry().serial == serial + 1 and tr.generation == generation, 'nothing resolves before a lookup')
assert(tr('panel.label') == 'PACK' and tr('panel.footer') == 'FOOTER' and tr.generation == generation + 1)
assert(tr('panel.more', {count = 1}):find('1', 1, true), 'bundled text still used where the pack has none')
assert(not tr:refresh() and tr.generation == generation + 1, 'one resolution per change')

-- Bad entries are refused one by one, logged once, and never break the mod.
logs = {}
T.register({language = 'zh-Hans', name = 'broken', mods = {know_your_constellation = {
    ['panel.label'] = 'bad \255 utf8', ['panel.more'] = 'no placeholder', ['panel.footer'] = 'ctrl\1',
    ['option.description'] = string.rep('x', 21), ['panel.unknown'] = 'x'}}})
assert(tr:refresh() and tr('panel.label') == 'PACK' and tr('panel.footer') == 'FOOTER', 'earlier valid texts stay')
assert(tr('option.description') == 'Short description.')
local joined_logs = table.concat(logs, '\n')
for _, reason in ipairs({'invalid UTF-8', 'placeholders differ', 'control character', 'longer than 20 characters',
                         'unknown key'}) do
    assert(joined_logs:find(reason, 1, true), 'logged: ' .. reason)
end
local count = #logs
T.registry().serial = T.registry().serial + 1
tr:refresh()
assert(#logs == count, 'the same problem is logged once')
-- Limits count characters, not bytes: 20 CJK characters (60 bytes) fit a 20 limit.
T.register({language = 'zh-Hans', name = 'long', mods = {know_your_constellation = {
    ['option.description'] = string.rep(zhong, 20)}}})
assert(tr:refresh() and tr('option.description') == string.rep(zhong, 20))
print('PASS: game language picks bundled texts; later packs win; bad entries are refused singly and logged once')

-- Fallback chain: a regional tag uses its base language, then English.
T = fresh()
T.registry().game_language = 'es-419'
local english_m = setmetatable({mod = 'm'}, {__index = english})
tr = T.new(english_m, {es = {language = 'es', strings = {['panel.footer'] = 'Posibles encuentros.'}}})
assert(tr('panel.footer') == 'Posibles encuentros.' and tr('panel.label') == 'FORECAST // INTEL AND RECON')
T.register({language = 'es-419', name = 'latam', mods = {m = {['panel.footer'] = 'LATAM'}}})
assert(tr:refresh() and tr('panel.footer') == 'LATAM', 'the regional pack wins over the base language')

-- A forced pack overrides the game's language, including English and pseudo.
T.register({language = 'en', name = 'english please', force = true, mods = {}})
assert(T.registry().override == 'en' and tr:refresh() and tr('panel.footer') == 'Possible encounters.')
T.register({language = 'pseudo', name = 'layout test', force = true, mods = {}})
assert(tr:refresh() and tr('panel.more', {count = 9}):find('9', 1, true) and tr('panel.label'):sub(1, 1) == '[')
print('PASS: regional tags fall back to their base language; a forced pack wins, including English and pseudo')

-- A broken registry (another copy, an add-on or a stray assignment) is repaired,
-- malformed packs are skipped, and only force = true forces a language.
T = fresh()
rawset(_G, 'BingusTranslations', {override = 'not a tag !', packs = 'oops'})
tr = T.new(english)
assert(tr('panel.footer') == 'Possible encounters.', 'a registry without packs or serial still resolves English')
local broken = T.registry()
assert(type(broken.packs) == 'table' and broken.serial == 0 and broken.version == 1, 'missing fields filled in')
broken.packs[#broken.packs + 1] = 42
broken.packs[#broken.packs + 1] = {language = 'zh-Hans', mods = 'not a table'}
broken.game_language = 'zh-Hans'
local footer = '可能的遭遇。'
T.register({language = 'zh-Hans', name = 'string force', force = 'false', mods = {
    know_your_constellation = {['panel.footer'] = footer}}})
assert(T.language() == 'zh-Hans', 'an invalid override is ignored; force = "false" does not force')
assert(tr:refresh() and tr('panel.footer') == footer, 'malformed packs are skipped, valid ones used')
assert(not pcall(T.register, {language = 'en us', mods = {}}), 'a pack without a language tag is refused')
print('PASS: a broken registry is repaired, malformed packs are skipped, and only force = true forces')

-- Upper case beyond ASCII (Mod Options Menu and Mod Bindings Menu upper-case names).
assert(T.upper('abc xyz 09') == 'ABC XYZ 09')
assert(T.upper('plong\195\169e \195\160 \195\191') == 'PLONG\195\137E \195\128 \197\184', 'Latin-1')
assert(T.upper('\197\188\195\179\197\130w \196\135') == '\197\187\195\147\197\129W \196\134', 'Polish')
assert(T.upper('\208\191\209\128\208\184\208\178\208\181\209\130 \209\145') == '\208\159\208\160\208\152\208\146\208\149\208\162 \208\129', 'Cyrillic')
assert(T.upper('\206\177\207\130\206\172') == '\206\145\206\163\206\134', 'Greek with final sigma and tonos')
assert(T.upper(zhong .. 'a\195\159') == zhong .. 'A\195\159', 'CJK and sharp s unchanged')
assert(T.upper('bad \255 x') == 'BAD \255 X', 'invalid bytes are kept, never re-encoded')
local already = 'ALREADY UPPER'
assert(T.upper(already) == already)
print('PASS: upper case covers Latin-1, Polish/Czech letters, Greek and Cyrillic; CJK and invalid bytes stay')

-- The game's Text Language, read through a mod's reader (build 25480438 layout).
local function fake_memory(code, index)
    local memory = {}
    local function put(address, bytes) for k = 1, #bytes do memory[address + k - 1] = bytes:sub(k, k) end end
    local function qword(value)
        local bytes = {}
        for k = 1, 8 do bytes[k] = string.char(value % 256) value = math.floor(value / 256) end
        return table.concat(bytes)
    end
    local game, settings, record, text = 0x7ff600000000, 0x20000000, 0x30000000, 0x30001000
    put(game + T.GAME.settings, qword(settings))
    put(settings + T.GAME.index, string.char(index, 0, 0, 0))
    put(game + T.GAME.table + 8 * index, qword(record))
    put(record + 8, qword(text))
    put(text, code .. '\0' .. string.rep('\0', 16))
    local reads = 0
    local function read(address, size)
        reads = reads + 1
        local out = {}
        for k = 0, size - 1 do
            out[#out + 1] = memory[address + k]
            if not out[#out] then return nil end
        end
        return table.concat(out)
    end
    return read, game, function() return reads end
end
T = fresh()
local read, game, reads = fake_memory('zh-CN', 11)
local tag, code = T.observe(read, game)
assert(tag == 'zh-Hans' and code == 'zh-CN' and reads() == 5, 'five reads, mapped to zh-Hans')
assert(T.registry().game_language == 'zh-Hans' and T.language() == 'zh-Hans')
local serial_after = T.registry().serial
assert(T.observe(read, game) == 'zh-Hans' and T.registry().serial == serial_after, 'unchanged: no serial bump')
read, game = fake_memory('us', 0)
assert(T.observe(read, game) == 'en' and T.registry().serial == serial_after + 1, 'a changed setting bumps the serial')
read, game = fake_memory('xx', 3)
assert(T.observe(read, game) == 'xx', 'an unknown code is kept as its own tag, so English shows')
-- Unreadable or implausible memory is "unknown", never a guess.
read, game = fake_memory('zh-TW', 15)
assert(T.observe(read, game) == nil, 'index out of the 15 records')
assert(T.observe(function() return nil end, 0x7ff600000000) == nil)
assert(T.observe(function() error('boom') end, 0x7ff600000000) == nil)
read, game = fake_memory('1234', 2)
assert(T.observe(read, game) == nil, 'codes are letters and hyphens')
assert(T.registry().game_language == 'xx', 'failed reads keep the last good value')
-- Mods that hold game.dll's base as a pointer (api.module returns uint8_t *)
-- pass it as is; the reader still gets numbers.
do
    local ffi = require('ffi')
    local numbers = true
    read, game = fake_memory('ko', 4)
    local function checked(address, size)
        numbers = numbers and type(address) == 'number'
        return read(address, size)
    end
    assert(T.observe(checked, ffi.cast('uint8_t *', game)) == 'ko' and numbers, 'pointer base, numeric reads')
    assert(T.observe(checked, 'game') == nil and T.observe(checked, nil) == nil)
end
print('PASS: the game\'s Text Language is read in five reads, mapped, and unreadable memory never guesses')

-- Two copies of this file (two mods) share one registry and interoperate.
T = fresh()
T.registry().game_language = 'zh-Hans'
local other = dofile(path)
assert(other ~= T and other.registry() == T.registry(), 'copies share _G.BingusTranslations')
local tr_a = T.new(setmetatable({mod = 'a'}, {__index = english}), nil)
local tr_b = other.new(setmetatable({mod = 'b'}, {__index = english}), nil)
other.register({language = 'zh-Hans', name = 'p', mods = {a = {['panel.label'] = 'A'}, b = {['panel.label'] = 'B'}}})
assert(tr_a('panel.label') == 'A' and tr_b('panel.label') == 'B')
-- A pack add-on registers without this file, exactly like this:
local registry = rawget(_G, 'BingusTranslations')
registry.packs[#registry.packs + 1] = {language = 'zh-Hans', name = 'inline', mods = {a = {['panel.label'] = 'INLINE'}}}
registry.serial = registry.serial + 1
assert(tr_a:refresh() and tr_a('panel.label') == 'INLINE' and tr_b:refresh() and tr_b('panel.label') == 'B')
print('PASS: two copies share one registry; a pack registered inline reaches every mod')

-- The unchanged-language check allocates nothing (it runs whenever a mod rebuilds its UI).
collectgarbage()
collectgarbage('stop')
local before = collectgarbage('count')
for _ = 1, 10000 do tr_a:refresh() end
for _ = 1, 10000 do tr_a('panel.label') end
local grown = collectgarbage('count') - before
collectgarbage('restart')
assert(grown < 1, 'refresh() and lookups allocated ' .. grown .. ' KB')
print('PASS: refresh() and lookups with nothing changed allocate nothing')

-- Steam: without the game (a test process) the language is unknown, then English; never an error.
T = fresh()
local steam = T.steam_language()
assert(steam == nil or type(steam) == 'string')
assert(T.language() == (steam and (T.STEAM[steam] or steam) or 'en'))
assert(T.registry().steam_language == (steam and (T.STEAM[steam] or steam) or false), 'cached once per session')
assert(T.steam_language() == steam, 'the declaration guard allows a second copy')
local second = dofile(path)
assert(second.steam_language() == steam, 'a second copy declares nothing twice')
-- The game's own setting wins over Steam once a mod has read it.
T.registry().game_language = 'ko'
assert(T.language() == 'ko')
print('PASS: the Steam language query fails soft outside the game and tolerates several copies')
