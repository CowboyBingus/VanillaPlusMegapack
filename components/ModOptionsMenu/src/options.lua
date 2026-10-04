-- Registered options: their texts (which may follow the game's language), their
-- values (applied, saved in ModOptionsMenu.values, and the player's pending
-- edits) and the option model register_option builds from a spec.
local mom = ...
local state, note, loader, translation = mom.state, mom.note, mom.loader, mom.translation
local TEXT_TEMPLATE = mom.TEXT_TEMPLATE -- '#COUNT': src/widgets.lua

-- Limits: characters of a description, names in a choice option.
local DESCRIPTION_LIMIT, MAX_CHOICES = 400, 16
local OFF_TEXT, ON_TEXT = 0xa090be2e, 0x13dc1da2
-- Choice words the game already translates; other text is shown verbatim.
local NATIVE_WORDS = {
    OFF = 0xa090be2e, ON = 0x13dc1da2, NO = 0xef21c0c2, YES = 0x30dbdb29,
    LOW = 0xe1f9ab36, MEDIUM = 0x3134d1fe, HIGH = 0x208f9597, ULTRA = 0x99ffb498,
    DEFAULT = 0x38e6b4e4, CUSTOM = 0x2acf00b1, NORMAL = 0xf3222616, INVERTED = 0x05478062,
    WEAK = 0xe7b8332e, STRONG = 0xd9709682, BASIC = 0xaab9e5da, ADVANCED = 0xe0b81607,
    FULL = 0x3ba052b7, PERFORMANCE = 0x5097df8c, BALANCED = 0xe2135504, QUALITY = 0x61f69557,
    GLOBAL = 0x1d256a7b, ALWAYS = 0xeccb0c50, DISABLED = 0xe480cc2b, HIDDEN = 0xaae829ed,
    VISIBLE = 0xbcab6809, SMALL = 0x818d7022, LARGE = 0xf8c59d6a, SHORT = 0xb008f033,
    DYNAMIC = 0xf54d4908, HOLD = 0x639ee7c1, PRESS = 0x91b91dd3, TAP = 0x26603652,
}
-- Seconds from a change to its save, and from a failed save to the next try.
local VALUES_FILE, SAVE_DELAY, SAVE_RETRY = 'ModOptionsMenu.values', 1, 10
-- The game keeps a slider's min, max, step and value as floats: a magnitude
-- above FLOAT_MAX reaches it as an infinity, a step below FLOAT_MIN (the
-- smallest normal float) as a denormal or 0.
local FLOAT_MAX, FLOAT_MIN, HUGE = 3.4028234663852886e38, 1.1754943508222875e-38, math.huge

-- Text -----------------------------------------------------------------------

local function display_text(text)
    return (text:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- A registered text: a string, or (API version 2) a function returning one,
-- which is called now and again whenever the escape menu opens, so the text
-- can follow the game's language. Limits count characters, so a Chinese or
-- Cyrillic text gets the same room as an English one. Returns the text to
-- show, or nil when the value is not a usable text.
function translation.resolve(value, limit)
    if type(value) == 'function' then
        local ok, result = pcall(value)
        if not ok then return nil end
        value = result
    end
    if type(value) ~= 'string' or translation.T.length(value) > limit then return nil end
    local text = display_text(value)
    if text == '' or not translation.T.check(text) then return nil end
    return text
end

-- Registered texts given as functions follow the game's language: they are
-- called again whenever the escape menu opens (never per frame). A result
-- that is no longer a usable text keeps the text shown before. Mods keep the
-- category they registered under; only its shown name changes.
function translation.refresh()
    local changed = false
    local function refreshed(value, source, limit, upper)
        if type(source) ~= 'function' then return value end
        local text = translation.resolve(source, limit)
        if not text then return value end
        if upper then text = translation.T.upper(text) end
        changed = changed or text ~= value
        return text
    end
    for _, mod in ipairs(state.mods) do mod.title = refreshed(mod.title, mod.source, 40, true) end
    for _, option in pairs(state.options) do
        local sources = option.sources
        option.label = refreshed(option.label, sources.label, 64)
        if option.description then
            option.description = refreshed(option.description, sources.description, DESCRIPTION_LIMIT)
        end
        for index, source in ipairs(sources.choices) do
            -- The game's own words keep the game's label.
            if option.labels[index] == TEXT_TEMPLATE then
                option.choices[index] = refreshed(option.choices[index], source, 48, true)
            end
        end
    end
    local title, empty = translation.tr('tab.mods'), translation.tr('category.none')
    changed = changed or title ~= state.mods_title or empty ~= state.empty_text
    state.mods_title, state.empty_text = title, empty
    if changed then state.revision = state.revision + 1 end
end

-- The game's Text Language (5 guarded reads), logged when it changes.
function translation.observe()
    local tag, code = translation.T.observe(translation.read, state.base)
    local seen = tag and (tag .. ' (game setting ' .. code .. ')') or (translation.T.language() .. ' (Steam)')
    if seen ~= state.language then
        state.language = seen
        note('Text language: ' .. seen .. '.')
    end
end

-- Values ---------------------------------------------------------------------

local function values_path()
    local directory = type(loader) == 'table' and loader.log_directory
    if type(directory) ~= 'string' or directory == '' then
        local local_app_data = os.getenv('LOCALAPPDATA')
        if not local_app_data then return nil end
        directory = local_app_data .. '/CowboyBingus/Helldivers2/Logs'
    end
    return directory .. '/' .. VALUES_FILE
end

-- The values file's text for id -> encoded value: a line of id, tab, value
-- each, sorted.
local function values_text(values)
    local lines = {}
    for id, text in pairs(values) do lines[#lines + 1] = id .. '\t' .. text end
    table.sort(lines)
    return table.concat(lines, '\n') .. '\n'
end

-- The text of a file, or nil when it cannot be read.
local function read_text(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end

-- id -> text for each line of a values file; nil when it holds none.
local function parse_values(text)
    local values, found = {}, false
    for id, value in text:gmatch('([^\t\r\n]+)\t([^\r\n]*)') do values[id], found = value, true end
    return found and values or nil
end

-- The saved values: the values file's, or its backup's when the file is
-- missing, unreadable or holds no value (as a save interrupted before v1.2
-- could leave it). state.written: the file's text as last read or written,
-- when MOM would write the same text for the same values (save_values skips
-- that text); never a backup's, so the next save writes the file.
local function saved_values()
    if state.saved then return state.saved end
    state.saved = {}
    local path = values_path()
    local text = path and read_text(path)
    local values = text and parse_values(text)
    if values then
        if values_text(values) == text then state.written = text end
    else
        values = path and parse_values(read_text(path .. '.bak') or '')
        if values then note('Option values read from the backup ' .. VALUES_FILE .. '.bak.') end
    end
    state.saved = values or state.saved
    return state.saved
end

local function encode(option, value)
    if option.kind == 'toggle' then return value and 'true' or 'false' end
    if option.kind == 'choice' then return tostring(value) end
    return string.format('%.6g', value)
end

local function valid_value(option, value)
    if option.kind == 'toggle' then return type(value) == 'boolean' end
    if type(value) ~= 'number' or value ~= value then return false end
    if option.kind == 'choice' then
        return value % 1 == 0 and value >= 1 and value <= #option.choices
    end
    return value >= option.min and value <= option.max
end

-- Slider values snap to the option's step; decimals avoid float noise. NaN
-- and the infinities snap to nil, which every caller refuses: a registered
-- default, set(), the values file and a row's value (src/rows.lua). Without
-- this, NaN came out as NaN or as min depending on whether the game's LuaJIT
-- had compiled the call (its compiled math.max drops a NaN).
local function snap(option, value)
    if not (value > -HUGE and value < HUGE) then return nil end
    local steps = math.floor((value - option.min) / option.step + 0.5)
    local snapped = math.min(option.max, math.max(option.min, option.min + steps * option.step))
    return tonumber(string.format('%.' .. option.decimals .. 'f', snapped))
end

local function decode(option, text)
    if option.kind == 'toggle' then
        if text == 'true' then return true elseif text == 'false' then return false end
        return nil
    end
    local value = tonumber(text)
    if value == nil then return nil end
    if option.kind == 'slider' then value = snap(option, value) end
    return valid_value(option, value) and value or nil
end

-- Writes the values file through <file>.tmp, checking every write and the
-- close, then moves the old file to <file>.bak and the temp file into its
-- place. A save interrupted at any point leaves the old file or, between the
-- two renames, its backup, which loading falls back to. Returns true, or false
-- and the reason; a failure leaves the old file in place.
local function write_values(path, text)
    local temp, backup = path .. '.tmp', path .. '.bak'
    local file, reason = io.open(temp, 'wb')
    if not file then return false, reason end
    local written, write_error = file:write(text)
    local closed, close_error = file:close()
    if not (written and closed) then
        os.remove(temp)
        return false, write_error or close_error
    end
    os.remove(backup)
    local moved = os.rename(path, backup)
    local replaced, rename_error = os.rename(temp, path)
    if replaced then return true end
    if moved then os.rename(backup, path) end
    os.remove(temp)
    return false, rename_error
end

-- Saves every value: saved ones of options not registered this session too.
-- A text the file already holds is not written again. A failed save keeps
-- the values due and tries again SAVE_RETRY seconds later; the first failure
-- after a save that worked is logged.
local function save_values()
    local path = values_path()
    local merged = {}
    for id, text in pairs(saved_values()) do merged[id] = text end
    for id, option in pairs(state.options) do merged[id] = encode(option, state.values[id]) end
    local text = values_text(merged)
    if text == state.written then state.dirty = false; return end
    local saved, reason = false, 'no folder for ' .. VALUES_FILE
    if path then saved, reason = write_values(path, text) end
    if saved then
        state.written, state.dirty, state.save_failed = text, false, false
        return
    end
    state.dirty, state.save_timer = true, SAVE_RETRY
    if not state.save_failed then note('Cannot save option values: ' .. tostring(reason)) end
    state.save_failed = true
end

local function changed(option, value)
    if state.values[option.id] == value then return end
    state.values[option.id] = value
    state.saved[option.id] = encode(option, value)
    state.dirty, state.save_timer = true, SAVE_DELAY
    for _, callback in ipairs(state.callbacks[option.id] or {}) do
        local ok, err = pcall(callback, value, option.id)
        if not ok then note('Option callback for ' .. option.id .. ' failed: ' .. tostring(err)) end
    end
end

-- Player edits wait for the apply action; editing back to the applied value
-- withdraws the edit.
local function set_pending(id, value)
    local had = state.pending[id] ~= nil
    if value == state.values[id] then value = nil end
    state.pending[id] = value
    if had ~= (value ~= nil) then state.pending_count = state.pending_count + (had and -1 or 1) end
end

-- What a row shows: the pending edit, else the applied value.
local function shown_value(option)
    local value = state.pending[option.id]
    if value == nil then value = state.values[option.id] end
    return value
end

-- Applies every pending edit in registration order, then saves at once, as
-- the game saves its settings on apply.
local function apply_pending()
    local options = {}
    for id in pairs(state.pending) do options[#options + 1] = state.options[id] end
    table.sort(options, function(a, b) return a.sequence < b.sequence end)
    local pending = state.pending
    state.pending, state.pending_count = {}, 0
    for _, option in ipairs(options) do changed(option, pending[option.id]) end
    save_values()
    return #options
end

local function drop_pending()
    state.pending, state.pending_count = {}, 0
end

-- Option model ---------------------------------------------------------------

-- The fields of one option type, from its spec. Each returns the option, or nil
-- and the reason when the spec does not describe a valid option of that type.
local function toggle_fields(option, spec)
    option.labels, option.default = {OFF_TEXT, ON_TEXT}, spec.default == true
    if spec.default ~= nil and type(spec.default) ~= 'boolean' then return nil, 'invalid default' end
    return option
end

local function choice_fields(option, spec)
    local choices = spec.choices
    if type(choices) ~= 'table' or #choices < 2 or #choices > MAX_CHOICES then
        return nil, 'choices must list 2 to ' .. MAX_CHOICES .. ' names'
    end
    option.choices, option.labels = {}, {}
    for index, choice in ipairs(choices) do
        local text = translation.resolve(choice, 48)
        if not text then return nil, 'invalid choice name' end
        option.choices[index] = translation.T.upper(text)
        -- A word the game translates itself (ON, OFF, LOW...) shows the game's own label.
        option.labels[index] = NATIVE_WORDS[option.choices[index]] or TEXT_TEMPLATE
        option.sources.choices[index] = choice
    end
    option.default = spec.default == nil and 1 or spec.default
    return option
end

-- Decimal places a slider shows: as many as its step needs, at most 3, and at
-- least 1 when min is not a whole number.
local function slider_decimals(min, step)
    local decimals = 0
    while decimals < 3 and math.abs(step * 10 ^ decimals - math.floor(step * 10 ^ decimals + 0.5)) > 1e-6 do
        decimals = decimals + 1
    end
    if min % 1 ~= 0 then decimals = math.max(decimals, 1) end
    return decimals
end

local function slider_fields(option, spec)
    local min, max, step = spec.min, spec.max, spec.step or 1
    if type(min) ~= 'number' or type(max) ~= 'number' or type(step) ~= 'number'
       or not (min < max) or step <= 0 or step > max - min then
        return nil, 'slider needs min < max and 0 < step <= max - min'
    end
    -- An infinity, a range or step a float cannot hold, or a NaN step (NaN
    -- fails every comparison above).
    if not (min >= -FLOAT_MAX and max <= FLOAT_MAX and max - min <= FLOAT_MAX and step >= FLOAT_MIN) then
        return nil, 'slider min, max and step must be finite floats'
    end
    option.min, option.max, option.step, option.decimals = min, max, step, slider_decimals(min, step)
    option.default = spec.default == nil and min or spec.default
    if type(option.default) == 'number' then option.default = snap(option, option.default) end
    return option
end

-- sources: the registered values (strings or functions), for translation.refresh.
local function new_option(id, spec)
    local kind = spec.type
    local option = {id = id, kind = kind, label = translation.resolve(spec.label, 64), gap = spec.gap == true,
                    sources = {label = spec.label, description = spec.description, choices = {}}}
    if spec.description ~= nil then
        option.description = translation.resolve(spec.description, DESCRIPTION_LIMIT)
        if not option.description then return nil, 'invalid description' end
    end
    local fields
    if kind == 'toggle' then
        fields = toggle_fields
    elseif kind == 'choice' then
        fields = choice_fields
    elseif kind == 'slider' then
        fields = slider_fields
    else
        return nil, 'type must be toggle, choice or slider'
    end
    local built, reason = fields(option, spec)
    if not built then return nil, reason end
    if not valid_value(option, option.default) then return nil, 'invalid default' end
    return option
end

-- Texts given as functions may differ between registrations (another
-- language): only texts given as strings are compared.
local function same_option(a, b)
    local function same_text(x, y, source_x, source_y)
        return type(source_x) == 'function' or type(source_y) == 'function' or x == y
    end
    local sa, sb = a.sources, b.sources
    if a.kind ~= b.kind or a.default ~= b.default or not same_text(a.label, b.label, sa.label, sb.label)
       or not same_text(a.description, b.description, sa.description, sb.description) then
        return false
    end
    if a.kind == 'choice' then
        if #a.choices ~= #b.choices then return false end
        for index = 1, #a.choices do
            if not same_text(a.choices[index], b.choices[index], sa.choices[index], sb.choices[index]) then
                return false
            end
        end
        return true
    end
    if a.kind == 'slider' then return a.min == b.min and a.max == b.max and a.step == b.step end
    return true
end

-- For the other files.
mom.display_text, mom.saved_values, mom.encode, mom.decode = display_text, saved_values, encode, decode
mom.valid_value, mom.snap, mom.save_values, mom.SAVE_DELAY = valid_value, snap, save_values, SAVE_DELAY
mom.set_pending, mom.shown_value = set_pending, shown_value
mom.apply_pending, mom.drop_pending = apply_pending, drop_pending
mom.new_option, mom.same_option, mom.MAX_CHOICES = new_option, same_option, MAX_CHOICES
