-- Bingus Text v1: translations and UTF-8 text layout for CowboyBingus mods.
--
-- Canonical copy: Translations/bingus_text.lua in the workspace. Every mod
-- that shows text carries a byte-identical src/bingus_text.lua. Copies share
-- translations only through the plain-data table _G.BingusTranslations, never
-- through functions, so mods built with different copies still agree:
--
--   version         1
--   serial          bumped by every change below; mods compare it to notice
--   packs           {language = 'zh-Hans', name = '...', force = false,
--                    mods = {mod_id = {key = text}}}
--   override        language of the last pack registered with force = true
--   game_language   tag of the game's Text Language setting, from game memory
--   game_code       that setting's own code (for example 'us')
--   steam_language  tag of Steam's game language (false when unknown)
--
-- Nothing here runs per frame. A mod resolves its texts when it builds its
-- UI; tr:refresh() costs one global read and two compares when nothing
-- changed. System calls: five memory reads through the mod's own reader
-- when it observes the game's language, and the Steam language query once
-- per session when that fails (both unmeasured in game).
local M = {VERSION = 1}

local byte, char, concat = string.byte, string.char, table.concat

-- The code point at byte i and the byte after it, or nil when the bytes at i
-- are not valid UTF-8 (overlong forms, surrogates and values above U+10FFFF
-- are invalid).
function M.decode(text, i)
    local c = byte(text, i)
    if not c then return nil end
    if c < 0x80 then return c, i + 1 end
    local n, value
    if c >= 0xC2 and c <= 0xDF then n, value = 1, c - 0xC0
    elseif c >= 0xE0 and c <= 0xEF then n, value = 2, c - 0xE0
    elseif c >= 0xF0 and c <= 0xF4 then n, value = 3, c - 0xF0
    else return nil end
    local lo, hi = 0x80, 0xBF
    if c == 0xE0 then lo = 0xA0 elseif c == 0xED then hi = 0x9F
    elseif c == 0xF0 then lo = 0x90 elseif c == 0xF4 then hi = 0x8F end
    for k = 1, n do
        local d = byte(text, i + k)
        if not d or d < lo or d > hi then return nil end
        value = value * 64 + (d - 0x80)
        lo, hi = 0x80, 0xBF
    end
    return value, i + n + 1
end

-- UTF-8 bytes of one code point.
function M.encode(value)
    if value < 0x80 then return char(value) end
    if value < 0x800 then return char(0xC0 + math.floor(value / 64), 0x80 + value % 64) end
    if value < 0x10000 then
        return char(0xE0 + math.floor(value / 4096), 0x80 + math.floor(value / 64) % 64, 0x80 + value % 64)
    end
    return char(0xF0 + math.floor(value / 262144), 0x80 + math.floor(value / 4096) % 64,
        0x80 + math.floor(value / 64) % 64, 0x80 + value % 64)
end

-- Text a mod may show: valid UTF-8 without control characters (a line feed
-- only where `multiline` allows it). Returns the text, or nil and the reason.
function M.check(text, multiline)
    if type(text) ~= 'string' then return nil, 'not a string' end
    local i, n = 1, #text
    while i <= n do
        local value, after = M.decode(text, i)
        if not value then return nil, 'invalid UTF-8 at byte ' .. i end
        if (value < 32 and not (multiline and value == 10)) or value == 127 or (value >= 0x80 and value < 0xA0) then
            return nil, 'control character at byte ' .. i
        end
        i = after
    end
    return text
end

-- check() that raises. Replaces the old plain-ASCII guards.
function M.display(text, multiline)
    local ok, why = M.check(text, multiline)
    if not ok then error('Unsupported display text: ' .. why, 2) end
    return text
end

-- Number of code points.
function M.length(text)
    local count, i, n = 0, 1, #text
    while i <= n do
        local _, after = M.decode(text, i)
        i, count = after or i + 1, count + 1
    end
    return count
end

-- Upper case for the scripts the game's fonts carry: ASCII, Latin-1, Latin
-- Extended-A (Polish, Czech...), Greek and Cyrillic. string.upper changes only
-- a-z, so 'Plongee' with an accent would come out half upper-cased. Other
-- characters (CJK, digits, sharp s) stay as they are.
local function upper_value(v)
    if v < 0x80 then return (v >= 0x61 and v <= 0x7A) and v - 32 or v end
    if v >= 0xE0 and v <= 0xFE and v ~= 0xF7 then return v - 32 end
    if v == 0xFF then return 0x178 end
    if v >= 0x100 and v <= 0x17F then
        if v == 0x131 then return 0x49 end
        if v == 0x17F then return 0x53 end
        if (v >= 0x139 and v <= 0x148) or (v >= 0x179 and v <= 0x17E) then
            return v % 2 == 0 and v - 1 or v
        end
        if v ~= 0x138 and v ~= 0x149 and v ~= 0x130 then return v % 2 == 1 and v - 1 or v end
        return v
    end
    if v >= 0x3B1 and v <= 0x3CB then return v == 0x3C2 and 0x3A3 or v - 32 end
    if v == 0x3AC then return 0x386 end
    if v >= 0x3AD and v <= 0x3AF then return v - 37 end
    if v == 0x3CC then return 0x38C end
    if v == 0x3CD or v == 0x3CE then return v - 63 end
    if v >= 0x430 and v <= 0x44F then return v - 32 end
    if v >= 0x450 and v <= 0x45F then return v - 80 end
    if v == 0x491 then return 0x490 end
    return v
end

function M.upper(text)
    if not text:find('[\97-\122\128-\255]') then return text end
    local parts, i, n = {}, 1, #text
    while i <= n do
        local value, after = M.decode(text, i)
        local changed = value and upper_value(value)
        if not value then after = i + 1 end
        parts[#parts + 1] = changed and changed ~= value and M.encode(changed) or text:sub(i, after - 1)
        i = after
    end
    return concat(parts)
end

-- The longest start of `text` that fits in `bytes` without cutting a
-- character: for the game's fixed-size text buffers.
function M.clip(text, bytes)
    if #text <= bytes then return text end
    local i = bytes + 1
    while i > 1 do
        local b = byte(text, i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return text:sub(1, i - 1)
end

local function set(list)
    local result = {}
    for _, value in ipairs(list) do result[value] = true end
    return result
end

-- Line breaking, a small subset of Unicode UAX #14. Never break before
-- closing punctuation, small kana or the prolonged sound mark, or after
-- opening punctuation and currency signs.
local CLOSE = set({0x21, 0x25, 0x29, 0x2C, 0x2E, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D,
    0x2010, 0x2013, 0x2019, 0x201D, 0x2025, 0x2026, 0x2030, 0x2103,
    0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B,
    0x301C, 0x301E, 0x301F, 0x303B,
    0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
    0x309B, 0x309C, 0x309D, 0x309E, 0x30A0, 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3,
    0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6, 0x30FB, 0x30FC, 0x30FD, 0x30FE,
    0xFF01, 0xFF05, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF5E, 0xFF60,
    0xFF61, 0xFF63, 0xFF64, 0xFF65})
local OPEN = set({0x24, 0x28, 0x5B, 0x7B, 0xA3, 0xA5, 0x2018, 0x201C, 0x20A9, 0x20AC,
    0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0x301D,
    0xFF04, 0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62, 0xFFE1, 0xFFE5})
local ZWJ = 0x200D

-- Characters that belong to the one before them: combining marks, joiners,
-- variation selectors, emoji skin tones, Hangul vowel and final jamo.
local function mark(v)
    return (v >= 0x300 and v <= 0x36F) or (v >= 0x483 and v <= 0x489) or v == 0xE31
        or (v >= 0xE34 and v <= 0xE3A) or (v >= 0xE47 and v <= 0xE4E) or (v >= 0x1160 and v <= 0x11FF)
        or (v >= 0x1AB0 and v <= 0x1AFF) or (v >= 0x1DC0 and v <= 0x1DFF) or v == 0x200C or v == ZWJ
        or (v >= 0x20D0 and v <= 0x20FF) or v == 0x3099 or v == 0x309A or (v >= 0xFE00 and v <= 0xFE0F)
        or (v >= 0xFE20 and v <= 0xFE2F) or (v >= 0x1F3FB and v <= 0x1F3FF) or (v >= 0xE0100 and v <= 0xE01EF)
end

-- Scripts written without spaces between words (Chinese, Japanese) and
-- Korean syllables: a line may break before or after any of these.
local function wide(v)
    return (v >= 0x1100 and v <= 0x115F) or (v >= 0x2E80 and v <= 0xA4CF) or (v >= 0xA960 and v <= 0xA97F)
        or (v >= 0xAC00 and v <= 0xD7FF) or (v >= 0xF900 and v <= 0xFAFF) or (v >= 0xFE10 and v <= 0xFE1F)
        or (v >= 0xFE30 and v <= 0xFE4F) or (v >= 0xFF00 and v <= 0xFF60) or (v >= 0xFFE0 and v <= 0xFFE6)
        or (v >= 0x1F300 and v <= 0x1FAFF) or (v >= 0x20000 and v <= 0x3FFFD)
end

local function space(v) return v == 32 or v == 0x3000 end

-- Byte offsets where each user-perceived character starts (a code point plus
-- the marks that follow it), then #text + 1. Scrolling and forced breaks cut
-- only here, so no character is ever split.
function M.boundaries(text)
    local list, i, n, previous = {}, 1, #text, nil
    while i <= n do
        local value, after = M.decode(text, i)
        if not value then value, after = 0xFFFD, i + 1 end
        if not previous or not (mark(value) or previous == ZWJ) then list[#list + 1] = i end
        previous, i = value, after
    end
    list[#list + 1] = n + 1
    return list
end

-- Unbreakable pieces of text: {first byte, last byte, separator before it,
-- line feeds before it}.
local function pieces(text)
    local list, i, n = {}, 1, #text
    local first, last, previous, gap, feeds = nil, nil, nil, '', 0
    local function finish()
        if first then
            list[#list + 1] = {first, last, gap, feeds}
            gap, feeds = '', 0
        end
        first = nil
    end
    while i <= n do
        local value, after = M.decode(text, i)
        if not value then value, after = 0xFFFD, i + 1 end
        if value == 10 then
            finish()
            feeds, gap, previous = feeds + 1, '', nil
        elseif space(value) and not first then
            gap = gap .. text:sub(i, after - 1)
        elseif space(value) then
            finish()
            gap, previous = text:sub(i, after - 1), nil
        else
            local join = first and (mark(value) or previous == ZWJ or CLOSE[value] or OPEN[previous]
                or not (wide(value) or wide(previous)))
            if join then last = after - 1
            else
                if first then finish() end
                first, last = i, after - 1
            end
            previous = value
        end
        i = after
    end
    finish()
    return list
end

-- Splits text into lines no wider than `width`, where measure(s) is the
-- drawn width of s. Lines break at spaces, and between CJK characters except
-- before closing or after opening punctuation. A piece wider than a whole
-- line breaks between characters. Spaces at a break are dropped.
function M.wrap(text, width, measure)
    local lines, line = {}, ''
    for _, piece in ipairs(pieces(text)) do
        local value = text:sub(piece[1], piece[2])
        for _ = 1, piece[4] do
            lines[#lines + 1] = line
            line = ''
        end
        local candidate = line == '' and value or line .. piece[3] .. value
        if measure(candidate) <= width then line = candidate
        else
            if line ~= '' then lines[#lines + 1] = line end
            if measure(value) <= width then line = value
            else
                line = ''
                local edges = M.boundaries(value)
                for k = 1, #edges - 1 do
                    local glyph = value:sub(edges[k], edges[k + 1] - 1)
                    if measure(line .. glyph) <= width then line = line .. glyph
                    else
                        assert(line ~= '', 'Text column too narrow')
                        lines[#lines + 1] = line
                        line = glyph
                    end
                end
            end
        end
    end
    if line ~= '' then lines[#lines + 1] = line end
    return lines
end

-- '{name}' placeholders are replaced by values.name; unknown names stay.
function M.format(text, values)
    return (text:gsub('{([%a_][%w_]*)}', function(name)
        local value = values[name]
        if value ~= nil then return tostring(value) end
    end))
end

-- Sorted placeholder names, to compare a translation with its English text.
function M.placeholders(text)
    local names = {}
    for name in text:gmatch('{([%a_][%w_]*)}') do names[#names + 1] = name end
    table.sort(names)
    return concat(names, ',')
end

-- Pseudo-translation for layout tests: accented letters the game's Latin
-- fonts carry (Latin-1 and Polish), 40% longer and bracketed, so clipped,
-- cut or untranslated text is easy to spot. Placeholders stay intact.
local PSEUDO = {a = 0xE1, c = 0xE7, d = 0xF0, e = 0xE9, i = 0xED, l = 0x142, n = 0xF1, o = 0xF6, s = 0x15B,
    u = 0xFC, y = 0xFD, z = 0x17C, A = 0xC1, C = 0xC7, D = 0xD0, E = 0xC9, I = 0xCD, L = 0x141, N = 0xD1,
    O = 0xD6, S = 0x15A, U = 0xDC, Y = 0xDD, Z = 0x17B}
function M.pseudo(text)
    local parts, i, n = {}, 1, #text
    while i <= n do
        local name = text:match('^{[%a_][%w_]*}', i)
        if name then
            parts[#parts + 1] = name
            i = i + #name
        else
            local c = text:sub(i, i)
            parts[#parts + 1] = PSEUDO[c] and M.encode(PSEUDO[c]) or c
            i = i + 1
        end
    end
    return '[' .. concat(parts) .. ' ' .. string.rep('~', math.max(2, math.ceil(M.length(text) * 0.4))) .. ']'
end

-- The shared table (see the top of this file), created on first use.
function M.registry()
    local registry = rawget(_G, 'BingusTranslations')
    if type(registry) ~= 'table' then
        registry = {version = 1, serial = 0, packs = {}}
        rawset(_G, 'BingusTranslations', registry)
    end
    return registry
end

-- Adds a translation pack. Pack add-ons do the same inline, without this file
-- (translations.py writes that code); keep the two identical.
function M.register(pack)
    assert(type(pack) == 'table' and type(pack.language) == 'string' and type(pack.mods) == 'table',
        'A translation pack needs a language and a mods table')
    local registry = M.registry()
    registry.packs[#registry.packs + 1] = pack
    if pack.force then registry.override = pack.language end
    registry.serial = registry.serial + 1
end

-- The game's Text Language (Options menu), which can differ from Steam's.
-- Build 25480438: the settings object [game.dll+0x3326340] + 705500 (what the
-- settings save 0x102f7a0 writes) holds at +212 an index into the table of
-- 15 language records at game.dll+0x37C5650; each record has its code string
-- at +8. Unreadable or implausible values mean "unknown", never a guess.
M.GAME = {settings = 0x3326340, index = 705500 + 212, table = 0x37C5650, count = 15}
-- Record codes to BCP 47 tags. Only 'us' is confirmed (English); the others
-- are the spellings the game's code tables use. An unlisted code is kept
-- as its own tag, so no translation matches it and English shows.
M.GAME_CODES = {us = 'en', en = 'en', ['en-US'] = 'en', uk = 'en-GB', gb = 'en-GB', ['en-GB'] = 'en-GB',
    de = 'de', fr = 'fr', it = 'it', es = 'es', ['es-ES'] = 'es', mx = 'es-419', ['es-MX'] = 'es-419',
    ['es-419'] = 'es-419', pl = 'pl', ru = 'ru', jp = 'ja', ja = 'ja', kr = 'ko', ko = 'ko', br = 'pt-BR',
    ['pt-BR'] = 'pt-BR', pt = 'pt', ['zh-CN'] = 'zh-Hans', cn = 'zh-Hans', zh = 'zh-Hans', zhs = 'zh-Hans',
    ['zh-TW'] = 'zh-Hant', tw = 'zh-Hant', zht = 'zh-Hant', cz = 'cs', cs = 'cs', gr = 'el', el = 'el',
    nl = 'nl', tr = 'tr', ua = 'uk'}

local function number(bytes)
    local value = 0
    for k = #bytes, 1, -1 do value = value * 256 + byte(bytes, k) end
    return value
end

-- The code of the game's Text Language, read through the mod's own
-- read(address, size) (a ReadProcessMemory wrapper: bad addresses fail, never
-- crash), which receives addresses as Lua numbers. `game` is game.dll's base
-- address, a number or a pointer. Five reads.
function M.game_code(read, game)
    if type(game) == 'cdata' then
        local ok, value = pcall(function() return tonumber(require('ffi').cast('uintptr_t', game)) end)
        game = ok and value or nil
    end
    if type(game) ~= 'number' then return nil end
    local function load(address, size)
        local ok, bytes = pcall(read, address, size)
        if ok and type(bytes) == 'string' and #bytes == size then return bytes end
    end
    local function pointer(address)
        local bytes = load(address, 8)
        local value = bytes and number(bytes)
        if value and value >= 65536 and value < 2 ^ 47 then return value end
    end
    local g = M.GAME
    local settings = pointer(game + g.settings)
    local index = settings and load(settings + g.index, 4)
    index = index and number(index)
    if not index or index >= g.count then return nil end
    local record = pointer(game + g.table + 8 * index)
    local text = record and pointer(record + 8)
    local bytes = text and (load(text, 16) or load(text, 8))
    local code = bytes and bytes:match('^(%a[%a%-]*)%z')
    if code and #code <= 12 then return code end
end

-- Records the game's Text Language for every mod. A mod that can read game
-- memory calls this at start, and again when it sees the native font change.
-- Returns the tag and the game's code, or nil when the setting is unreadable.
function M.observe(read, game)
    local code = M.game_code(read, game)
    if not code then return nil end
    local tag = M.GAME_CODES[code] or code
    local registry = M.registry()
    if registry.game_language ~= tag then
        registry.game_language, registry.game_code = tag, code
        registry.serial = registry.serial + 1
    end
    return tag, code
end

-- Steam language names (ISteamApps::GetCurrentGameLanguage), as the game's
-- own Localization module reads them, to BCP 47 tags.
M.STEAM = {english = 'en', schinese = 'zh-Hans', tchinese = 'zh-Hant', koreana = 'ko', japanese = 'ja',
    russian = 'ru', polish = 'pl', french = 'fr', german = 'de', italian = 'it', spanish = 'es',
    latam = 'es-419', brazilian = 'pt-BR', portuguese = 'pt', ukrainian = 'uk', czech = 'cs', dutch = 'nl',
    turkish = 'tr', thai = 'th', vietnamese = 'vi', danish = 'da', finnish = 'fi', norwegian = 'no',
    swedish = 'sv', hungarian = 'hu', romanian = 'ro', bulgarian = 'bg', greek = 'el', arabic = 'ar',
    indonesian = 'id'}

-- Steam's current game language, which the game starts from until the player
-- picks a Text Language. Made once per session and only when the game's own
-- setting is unreadable: two lookups in steam_api64.dll, which the game has
-- already loaded (nothing is loaded), and two calls into it.
function M.steam_language()
    local ok, name = pcall(function()
        local ffi = require('ffi')
        -- Declared once per process, whichever copy of this file comes first,
        -- under this file's own names (asm labels): no mod's declaration of
        -- the same Windows functions can clash with these.
        if not pcall(ffi.typeof, 'bingus_steam_apps_fn') then
            ffi.cdef[[
                typedef void *(*bingus_steam_apps_fn)(void);
                typedef const char *(*bingus_steam_language_fn)(void *apps);
                void *bingus_text_module(const char *name) __asm__("GetModuleHandleA");
                void *bingus_text_export(void *module, const char *name) __asm__("GetProcAddress");
            ]]
        end
        local steam = ffi.C.bingus_text_module('steam_api64.dll')
        if steam == nil then return nil end
        local apps_fn = ffi.C.bingus_text_export(steam, 'SteamAPI_SteamApps_v008')
        local language_fn = ffi.C.bingus_text_export(steam, 'SteamAPI_ISteamApps_GetCurrentGameLanguage')
        if apps_fn == nil or language_fn == nil then return nil end
        local apps = ffi.cast('bingus_steam_apps_fn', apps_fn)()
        if apps == nil then return nil end
        local value = ffi.cast('bingus_steam_language_fn', language_fn)(apps)
        return value ~= nil and ffi.string(value) or nil
    end)
    return ok and name or nil
end

-- The game's language: its Text Language setting when a mod observed it,
-- else Steam's game language.
function M.game_language()
    local registry = M.registry()
    if registry.game_language then return registry.game_language end
    if registry.steam_language == nil then
        local name = M.steam_language()
        registry.steam_language = name and (M.STEAM[name] or name) or false
    end
    return registry.steam_language or nil
end

-- The language mods show: a forced pack's, else the game's, else English.
function M.language()
    local override = M.registry().override
    if type(override) == 'string' and override ~= '' then return override end
    return M.game_language() or 'en'
end

-- Tags tried for a language, least specific first: 'zh-Hant' tries 'zh',
-- then 'zh-Hant'. Keys missing from both show in English.
local function chain(language)
    local base = language:match('^([^-]+)-')
    return base and {base, language} or {language}
end

local translator = {}
translator.__index = translator
translator.__call = function(self, key, values) return self:text(key, values) end

-- A translator for one mod. `english` is the mod's locales/en.lua table:
-- {mod = 'mod_id', language = 'en', strings = {key = text},
-- limits = {key = characters}, multiline = {key = true}}; `bundled` maps
-- language tags to the other locale files shipped in the mod; log(message)
-- receives rejected entries and one summary line per language.
function M.new(english, bundled, log)
    assert(type(english) == 'table' and type(english.strings) == 'table', 'English texts required')
    local mod = english.mod
    assert(type(mod) == 'string' and mod:match('^[%l%d_]+$'), 'Invalid mod id')
    local limits, multiline = english.limits or {}, english.multiline or {}
    for key, text in pairs(english.strings) do
        assert(type(key) == 'string' and key:match('^[%w_.%-]+$'), 'Invalid text key')
        assert(M.check(text, multiline[key]), 'Invalid English text: ' .. key)
        assert(not limits[key] or M.length(text) <= limits[key], 'English text over its limit: ' .. key)
    end
    return setmetatable({mod = mod, english = english.strings, limits = limits, multiline = multiline,
        bundled = bundled or {}, log = log, logged = {}}, translator)
end

function translator:warn(message)
    if self.log and not self.logged[message] then
        self.logged[message] = true
        self.log(message)
    end
end

-- Copies the valid entries of one source over `texts` and marks them in
-- `translated`. Invalid entries keep the text they would have replaced.
function translator:merge(texts, translated, source, origin)
    if type(source) ~= 'table' then return end
    for key, text in pairs(source) do
        local english = self.english[key]
        local ok, why = english ~= nil, 'unknown key'
        if ok then ok, why = M.check(text, self.multiline[key]) end
        if ok and M.placeholders(text) ~= M.placeholders(english) then ok, why = nil, 'placeholders differ from English' end
        if ok and self.limits[key] and M.length(text) > self.limits[key] then
            ok, why = nil, 'longer than ' .. self.limits[key] .. ' characters'
        end
        if ok then
            texts[key], translated[key] = text, true
        else
            self:warn('translation ' .. origin .. ': ' .. tostring(key) .. ': ' .. why)
        end
    end
end

function translator:resolve(language, registry)
    local texts = {}
    for key, text in pairs(self.english) do texts[key] = text end
    if language == 'pseudo' then
        for key, text in pairs(texts) do texts[key] = M.pseudo(text) end
    elseif language ~= 'en' then
        local translated = {}
        for _, tag in ipairs(chain(language)) do
            local bundled = self.bundled[tag]
            self:merge(texts, translated, bundled and bundled.strings, tag .. ' (bundled)')
            for _, pack in ipairs(registry.packs) do
                if pack.language == tag and type(pack.mods) == 'table' then
                    self:merge(texts, translated, pack.mods[self.mod], tag .. ' (' .. tostring(pack.name) .. ')')
                end
            end
        end
        local count, total = 0, 0
        for key in pairs(self.english) do
            total = total + 1
            if translated[key] then count = count + 1 end
        end
        self:warn('language ' .. language .. ': ' .. count .. ' of ' .. total .. ' texts translated')
    end
    self.texts, self.language, self.serial = texts, language, registry.serial
    self.generation = (self.generation or 0) + 1
end

-- Resolves again when the language or the installed packs changed. Returns
-- true when it did. Every lookup does this too (a menu host may call a mod's
-- text function at any time), so a mod that caches what it drew compares
-- tr.generation, which grows with every resolution, not this return value.
function translator:refresh()
    local registry = M.registry()
    local language = M.language()
    if self.texts and self.serial == registry.serial and self.language == language then return false end
    self:resolve(language, registry)
    return true
end

-- The text for `key` in the current language, placeholders filled from
-- `values`.
function translator:text(key, values)
    self:refresh()
    local text = self.texts[key]
    if text == nil then error('Unknown text key: ' .. tostring(key), 2) end
    return values and M.format(text, values) or text
end

-- Keep this rarely run code interpreted: it must not add traces to the
-- game's shared LuaJIT code cache.
if jit and jit.off then
    for _, fn in ipairs({M.decode, M.encode, M.check, M.display, M.length, upper_value, M.upper, M.clip, mark,
                         wide, space, M.boundaries, pieces, M.wrap, M.format, M.placeholders, M.pseudo,
                         M.registry, M.register, number, M.game_code, M.observe, M.steam_language,
                         M.game_language, M.language, chain, M.new, translator.warn, translator.merge,
                         translator.resolve, translator.refresh, translator.text}) do
        jit.off(fn, true)
    end
end

return M
