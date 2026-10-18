-- Mod Bindings Menu's extended bindings file: the keys the player chose for
-- bindings that have no native action (src/extended.lua), saved safely.
-- src/mod_bindings_menu.lua runs this file once as mbm_files.extended_store(mbm);
-- it adds load_extended, flush_extended, parse_extended, extended_text and
-- EXTENDED_FORMAT to mbm.
--
-- The file, ModBindingsMenu.bindings beside the assignments file, holds one
-- record per line and is only ever parsed as data:
--   format 1
--   <id>\tset\t<alternative>|<alternative>...   the player's binding
--   <id>\tcleared                               the player removed every key:
--                                               the author's default is not used
--   <id>\tdefault                               the author's default applies
--   end                                         a complete file always ends with it
-- An alternative is <input>(+<input>)*@<trigger>: the first input is the one
-- that triggers, each +input must be held with it (modifiers). An input is
-- <device>:<index>, device k (keyboard), m (mouse) or p (controller) and index
-- the engine's button index on that device; trigger press, release or hold.
-- Every extended binding has a line, so an id stays extended in later sessions
-- even when a native action is free then: a binding never changes backend.
--
-- Safety. A line this version cannot read (another device, trigger or verb,
-- written by a newer version) is kept verbatim and written back; its binding
-- stays inactive and is never replaced by its default. A file of a newer format
-- is not changed at all, and every extended binding stays inactive. A damaged
-- file (no end line) is replaced by its backup when that is usable; without
-- one it is set aside as <file>.damaged before the next save, never
-- overwritten. Saves go through <file>.tmp and keep the previous file as
-- <file>.bak (src/assignments.lua's replace_file).
local mbm = ...
local state, note = mbm.state, mbm.note
local settings_path, replace_file, file_exists, SAVE_RETRY = mbm.settings_path, mbm.replace_file, mbm.file_exists,
                                                            mbm.SAVE_RETRY

local EXTENDED_FILE = 'ModBindingsMenu.bindings'
local FORMAT = 1
-- Sanity limits of the parser; none of them limits how many bindings exist.
local MAX_TEXT, MAX_LINE, MAX_ALTERNATIVES, MAX_INPUTS = 4 * 1024 * 1024, 4096, 16, 5
local DEVICES = {k = true, m = true, p = true}
local TRIGGERS = {press = true, release = true, hold = true}

local function extended_path() return settings_path(EXTENDED_FILE) end

-- An alternative from its text, or nil when this version cannot read it.
local function parse_alternative(text)
    local inputs_text, trigger = text:match('^([^@]+)@(%a+)$')
    if not inputs_text or not TRIGGERS[trigger] then return nil end
    local inputs = {}
    for input in (inputs_text .. '+'):gmatch('([^+]*)%+') do
        local device, index = input:match('^(%a):(%d+)$')
        if not device or not DEVICES[device] or #inputs >= MAX_INPUTS then return nil end
        index = tonumber(index)
        if index > 65535 then return nil end
        inputs[#inputs + 1] = {device = device, index = index}
    end
    if #inputs == 0 then return nil end
    return {inputs = inputs, trigger = trigger}
end

local function alternative_text(alternative)
    local parts = {}
    for index, input in ipairs(alternative.inputs) do parts[index] = input.device .. ':' .. input.index end
    return table.concat(parts, '+') .. '@' .. alternative.trigger
end

-- A record from a line: {kind = 'set', alternatives}, {kind = 'cleared'},
-- {kind = 'default'} or {kind = 'unknown', line}; nil for a line without an id.
local function parse_record(line)
    local id, verb, rest = line:match('^([^\t]+)\t(%a+)\t?(.*)$')
    if not id then return nil end
    if (verb == 'cleared' or verb == 'default') and rest == '' then return id, {kind = verb} end
    if verb == 'set' and #line <= MAX_LINE then
        local alternatives = {}
        for part in (rest .. '|'):gmatch('([^|]*)|') do
            local alternative = parse_alternative(part)
            if not alternative or #alternatives >= MAX_ALTERNATIVES then
                return id, {kind = 'unknown', line = line}
            end
            alternatives[#alternatives + 1] = alternative
        end
        if #alternatives > 0 then return id, {kind = 'set', alternatives = alternatives} end
    end
    return id, {kind = 'unknown', line = line}
end

local function new_store()
    return {records = {}, format = FORMAT, dirty = false, failed = false, retry = 0, damaged = false,
            set_aside = false, newer = false}
end

-- The store in text: a store, or nil and 'damaged' (cut short, no format line,
-- too long) or 'newer' (a later format, kept as it is).
local function parse_extended(text)
    if #text > MAX_TEXT then return nil, 'damaged' end
    local lines = text:gmatch('[^\r\n]+')
    local format = tonumber((lines() or ''):match('^format (%d+)$'))
    if not format then return nil, 'damaged' end
    if format > FORMAT then return nil, 'newer' end
    local store = new_store()
    -- Lines after 'end' are ignored; without it the file was cut short.
    for line in lines do
        if line == 'end' then return store end
        local id, record = parse_record(line)
        if id then store.records[id] = record end
    end
    return nil, 'damaged'
end

-- The file's text for store: sorted by id, unknown lines verbatim.
local function extended_text(store)
    local ids = {}
    for id in pairs(store.records) do ids[#ids + 1] = id end
    table.sort(ids)
    local lines = {'format ' .. FORMAT}
    for _, id in ipairs(ids) do
        local record = store.records[id]
        if record.kind == 'unknown' then
            lines[#lines + 1] = record.line
        elseif record.kind == 'cleared' or record.kind == 'default' then
            lines[#lines + 1] = id .. '\t' .. record.kind
        else
            local parts = {}
            for index, alternative in ipairs(record.alternatives) do parts[index] = alternative_text(alternative) end
            lines[#lines + 1] = id .. '\tset\t' .. table.concat(parts, '|')
        end
    end
    lines[#lines + 1] = 'end'
    return table.concat(lines, '\n') .. '\n'
end

local function read_text(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    if not text or text == '' then return nil end
    return text
end

-- Loads the file once per session: the file, else its backup (written back at
-- the next save), else a new store. state.extended_store = {records, text = the
-- file as read or last written, dirty, failed, retry, damaged = only the backup
-- is usable, set_aside = a damaged file without backup is moved away before the
-- next save, newer = a later format: never written}.
-- The store when the file (text, nil when missing) cannot be used: its
-- backup, else a new store; a damaged file is then set aside at the next save.
local function fallback_store(path, text)
    local backup = path and read_text(path .. '.bak')
    local store = backup and parse_extended(backup)
    if store then
        store.dirty, store.damaged = true, text ~= nil
        note('Extended bindings restored from ' .. EXTENDED_FILE .. '.bak; the file was ' ..
             (text and 'damaged.' or 'missing.'))
        return store
    end
    store = new_store()
    if text then
        store.set_aside = true
        note('The extended bindings file is damaged and has no usable backup; it will be kept as ' ..
             EXTENDED_FILE .. '.damaged, and extended bindings start from their defaults.')
    end
    return store
end

local function load_extended()
    if state.extended_store then return state.extended_store end
    local path, store, problem = extended_path(), nil, nil
    local text = path and read_text(path)
    if text then store, problem = parse_extended(text) end
    if store then
        store.text = text
    elseif problem == 'newer' then
        store = new_store()
        store.newer = true
        note('The extended bindings file was written by a newer Mod Bindings Menu; it is left as it is, and ' ..
             'extended bindings stay inactive.')
    else
        store = fallback_store(path, text)
    end
    state.extended_store = store
    return store
end

-- Saves a changed store, from the step. Unchanged stores are not written; a
-- failed save keeps the changes, logs once, shows on the page (state.save_problem)
-- and is tried again SAVE_RETRY seconds later. A newer-format file is never written.
-- Writes text to path, a damaged file set aside first: true, or false and why.
local function write_store(store, path, text)
    if not path then return false, 'no settings folder' end
    if store.set_aside then
        -- An earlier .damaged file is kept too: this one gets a name of its own.
        local moved = not file_exists(path) or os.rename(path, path .. '.damaged')
                      or os.rename(path, path .. '.damaged-' .. os.time())
        if not moved then return false, 'cannot set the damaged file aside' end
        store.set_aside = false
    end
    return replace_file(path, text, store.damaged)
end

local function save_failed(store, problem)
    store.retry = SAVE_RETRY
    state.save_problem = tostring(problem)
    if store.failed then return end
    store.failed = true
    note('Cannot save extended bindings (' .. tostring(problem) .. '); keeping them and trying again in ' ..
         SAVE_RETRY .. ' seconds.')
end

local function flush_extended(seconds)
    local store = state.extended_store
    if not store or not store.dirty then return end
    if store.newer then
        store.dirty = false
        return
    end
    if store.retry > 0 then
        store.retry = store.retry - seconds
        return
    end
    local text = extended_text(store)
    local saved, problem = text == store.text, nil
    if not saved then saved, problem = write_store(store, extended_path(), text) end
    if not saved then
        save_failed(store, problem)
        return
    end
    if store.failed then note('Saved extended bindings after an earlier failure.') end
    store.text, store.dirty, store.failed, store.damaged = text, false, false, false
    state.save_problem = nil
end

mbm.load_extended, mbm.flush_extended, mbm.parse_extended, mbm.extended_text = load_extended, flush_extended,
                                                                             parse_extended, extended_text
mbm.parse_alternative, mbm.alternative_text, mbm.EXTENDED_FORMAT, mbm.EXTENDED_FILE = parse_alternative,
    alternative_text, FORMAT, EXTENDED_FILE
mbm.MAX_ALTERNATIVES, mbm.MAX_INPUTS = MAX_ALTERNATIVES, MAX_INPUTS
