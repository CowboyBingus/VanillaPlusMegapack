-- Mod Bindings Menu's assignments file and reservations: the native action of
-- each automatic binding, kept for its id across sessions and saved safely.
-- src/mod_bindings_menu.lua runs this file once as mbm_files.assignments(mbm);
-- it adds load_assignments, flush_assignments and assign_action to mbm.
local mbm = ...
local bit = require('bit')
local state, note = mbm.state, mbm.note
local DORMANT_ACTIONS, SLOTS, ASSIGNMENTS_FILE = mbm.DORMANT_ACTIONS, mbm.SLOTS, mbm.ASSIGNMENTS_FILE

local function assignments_path()
    local loader_api = rawget(_G, 'CowboyBingusModLoader')
    local directory = type(loader_api) == 'table' and loader_api.log_directory
    if type(directory) ~= 'string' or directory == '' then
        local local_app_data = os.getenv('LOCALAPPDATA')
        if not local_app_data then return nil end
        directory = local_app_data .. '/CowboyBingus/Helldivers2'
    end
    return directory .. '/' .. ASSIGNMENTS_FILE
end

-- Automatic bindings keep their native action across sessions, because the
-- game saves each action's keys under the action's name. The assignments file,
-- format 2, holds one record per line:
--   format 2
--   session <n>                         the number of the last session that
--                                       counted (see count_session)
--   <id>\t<group>\t<action>\t<seen>     an automatic binding and the last
--                                       session it registered in
--   action <group>:<action> cleared <session> found <hash> left <hash>
--                                       the sweep cleared the action's inherited
--                                       developer defaults in that session: the
--                                       fingerprints of the list it found and of
--                                       the list it last left (src/sweep.lua)
--   action <group>:<action> clear       handed over from an expired binding:
--                                       to be cleared entirely
--   end                                 a complete file always ends with it
-- v2.1 wrote only "<id>\t<group>\t<action>" lines.
local function new_book()
    return {bindings = {}, holders = {}, actions = {}, saved = 0, counted = false, dirty = false, failed = false,
            retry = 0, damaged = false}
end

-- A binding read from the file: bindings = {[id] = {code, seen}} and
-- holders = {[code] = id}. An action held twice keeps its latest binding.
local function read_binding(book, id, code, seen)
    if not state.auto_codes[code] then return end
    local holder = book.holders[code]
    local other = holder and book.bindings[holder]
    if other and (other.seen or 0) >= (seen or 0) then return end
    if other then book.bindings[holder] = nil end
    local before = book.bindings[id]
    if before and book.holders[before.code] == id then book.holders[before.code] = nil end
    book.bindings[id], book.holders[code] = {code = code, seen = seen}, id
end

-- An action record: {cleared = session, found = fingerprint, left = fingerprint}
-- or {clear = true}, for dormant actions only.
local function read_action(book, code, record)
    if not state.code_order[code] then return end
    if record == 'clear' then
        book.actions[code] = {clear = true}
        return
    end
    local cleared, found, left = record:match('^cleared (%d+) found (%x+) left (%x+)$')
    if cleared then
        book.actions[code] = {cleared = tonumber(cleared), found = bit.tobit(tonumber(found, 16)),
                              left = bit.tobit(tonumber(left, 16))}
    end
end

local function read_line(book, line)
    local id, group, action, seen = line:match('^([^\t]+)\t(%d+)\t(%d+)\t?(%d*)$')
    if id then return read_binding(book, id, tonumber(group) * 65536 + tonumber(action), tonumber(seen)) end
    group, action, seen = line:match('^action (%d+):(%d+) (.+)$')
    if group then return read_action(book, tonumber(group) * 65536 + tonumber(action), seen) end
    if line == 'end' then
        book.complete = true
        return
    end
    local key, value = line:match('^(%a+) (%d+)$')
    if key == 'format' then book.format = tonumber(value)
    elseif key == 'session' then book.saved = tonumber(value) end
end

-- The assignments in text, or nil when a format 2 file was cut short. v2.1
-- bindings count as last seen in the session that saved the file.
local function parse_assignments(text)
    local book = new_book()
    for line in text:gmatch('[^\r\n]+') do read_line(book, line) end
    if book.format and not book.complete then return nil end
    for _, binding in pairs(book.bindings) do binding.seen = binding.seen or book.saved end
    return book
end

local function file_exists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

-- The assignments in the file at path, or nil when it is missing, empty or
-- cut short. book.text keeps the file's text.
local function read_assignments(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    if not text or text == '' then return nil end
    local book = parse_assignments(text)
    if book then book.text = text end
    return book
end

-- The backup, for a file that is missing (a save interrupted between its
-- renames leaves only the backup) or unusable. It is written back at the next
-- save, without touching the good backup.
local function restore_assignments(path)
    local damaged = file_exists(path)
    local book = read_assignments(path .. '.bak')
    if book then
        book.text, book.dirty, book.damaged = nil, true, damaged
        note('Binding assignments restored from ' .. ASSIGNMENTS_FILE .. '.bak; the file was ' ..
             (damaged and 'damaged.' or 'missing.'))
        return book
    end
    if damaged then note('The binding assignments file is damaged and has no backup; automatic bindings start over.') end
    return nil
end

-- Loads the assignments once per session, which gets the next session number.
-- state.assignments = {bindings, holders, actions, session = this session's
-- number, saved = the number in the file, counted = this session counts,
-- text = the file as read or last written, dirty = unsaved changes, failed =
-- the last save failed (logged once), retry = seconds before the next attempt,
-- damaged = only the backup is usable}.
local function load_assignments()
    if state.assignments then return state.assignments end
    local path = assignments_path()
    local book = path and (read_assignments(path) or restore_assignments(path)) or new_book()
    book.session = book.saved + 1
    state.assignments = book
    return book
end

-- A session counts towards the expiry of reservations from the first time a
-- mod asks for an automatic binding in it, whether it gets one or not: a mod
-- refused for the reservations of mods that are gone must see them expire. Its
-- number is saved only then, and only a session whose bindings work saves, so
-- launches without such mods (test runs included) and sessions on an
-- unsupported game build never age a reservation.
local function count_session(book)
    if book.counted then return end
    book.counted, book.dirty = true, true
end

local function action_line(code, action)
    local name = 'action ' .. math.floor(code / 65536) .. ':' .. code % 65536
    if action.clear then return name .. ' clear' end
    return name .. ' cleared ' .. action.cleared .. ' found ' .. bit.tohex(action.found) .. ' left ' ..
           bit.tohex(action.left)
end

local function assignments_text(book)
    local lines = {}
    for id, binding in pairs(book.bindings) do
        lines[#lines + 1] = id .. '\t' .. math.floor(binding.code / 65536) .. '\t' .. binding.code % 65536 ..
                            '\t' .. binding.seen
    end
    table.sort(lines)
    table.insert(lines, 1, 'format 2')
    table.insert(lines, 2, 'session ' .. (book.counted and book.session or book.saved))
    for _, entry in ipairs(DORMANT_ACTIONS) do
        local code = entry[1] * 65536 + entry[2]
        if book.actions[code] then lines[#lines + 1] = action_line(code, book.actions[code]) end
    end
    lines[#lines + 1] = 'end'
    return table.concat(lines, '\n') .. '\n'
end

-- Moves the current file out of the way: to the backup, or deleted when it is
-- damaged (the backup then holds the good copy). True when path is free.
local function set_aside(path, backup, damaged)
    if not file_exists(path) then return true end
    if damaged then return os.remove(path) end
    os.remove(backup)
    return os.rename(path, backup)
end

-- Writes text to path through <path>.tmp, every write and the close checked;
-- the old file becomes <path>.bak, then the new one is renamed into place.
-- Returns true, or false and the reason; on failure the old file stays.
local function replace_file(path, text, damaged)
    local temporary, backup = path .. '.tmp', path .. '.bak'
    local file, problem = io.open(temporary, 'wb')
    if not file then return false, problem end
    local written, write_problem = file:write(text)
    local closed, close_problem = file:close()
    if not (written and closed) then
        os.remove(temporary)
        return false, write_problem or close_problem
    end
    local moved, move_problem = set_aside(path, backup, damaged)
    if not moved then
        os.remove(temporary)
        return false, move_problem
    end
    local placed, place_problem = os.rename(temporary, path)
    if placed then return true end
    if not damaged then os.rename(backup, path) end
    os.remove(temporary)
    return false, place_problem
end

local SAVE_RETRY = 60 -- seconds before a failed save is tried again
-- Saves changed assignments, from the step (never inside another mod's call).
-- Unchanged assignments are not written. A failed save keeps them dirty, logs
-- once and is tried again SAVE_RETRY seconds later.
local function flush_assignments(seconds)
    local book = state.assignments
    if book.retry > 0 then
        book.retry = book.retry - seconds
        return
    end
    local text, path = assignments_text(book), assignments_path()
    local saved, problem = text == book.text, 'no settings folder'
    if not saved and path then saved, problem = replace_file(path, text, book.damaged) end
    if saved then
        if book.failed then note('Saved binding assignments after an earlier failure.') end
        book.text, book.dirty, book.failed, book.damaged = text, false, false, false
        return
    end
    book.retry = SAVE_RETRY
    if book.failed then return end
    book.failed = true
    note('Cannot save binding assignments (' .. tostring(problem) .. '); keeping them and trying again in ' ..
         SAVE_RETRY .. ' seconds.')
end

-- Reservations. An automatic action stays reserved for its binding id across
-- sessions, also in a session where the id registers late or not at all, until
-- the id has not registered for EXPIRY_SESSIONS sessions that count (see
-- count_session). A new id takes a free action, else the action of the
-- binding absent longest once its reservation has ended (its keys are then
-- cleared); else registration fails with a reason.
local EXPIRY_SESSIONS = 30
local AUTO_ACTIONS = #DORMANT_ACTIONS - SLOTS
local REASON_RESERVED = 'no free binding action; the others are reserved by mods not loaded this session'
local REASON_FULL = 'all ' .. AUTO_ACTIONS .. ' automatic binding actions in use'

local function auto_code(index)
    return DORMANT_ACTIONS[index][1] * 65536 + DORMANT_ACTIONS[index][2]
end

-- Whether the binding missed its last EXPIRY_SESSIONS sessions (this one,
-- still running, does not count).
local function expired(book, binding)
    return book.session - binding.seen - 1 >= EXPIRY_SESSIONS
end

-- The first automatic action that no binding holds and none uses.
local function free_action(book)
    for index = SLOTS + 1, #DORMANT_ACTIONS do
        local code = auto_code(index)
        if not state.used[code] and not book.holders[code] then return code end
    end
    return nil
end

-- The action of the binding absent longest, once its reservation has ended.
local function expired_action(book)
    local oldest, oldest_seen
    for index = SLOTS + 1, #DORMANT_ACTIONS do
        local code = auto_code(index)
        local holder = book.holders[code]
        local binding = holder and book.bindings[holder]
        if binding and not state.used[code] and expired(book, binding)
           and (not oldest or binding.seen < oldest_seen) then
            oldest, oldest_seen = code, binding.seen
        end
    end
    return oldest
end

-- Gives code to id. An expired binding that held it loses it, and its keys are
-- cleared so they do not carry over to the new binding.
local function hand_over(book, id, code)
    local previous = book.holders[code]
    if previous then
        note('Native action ' .. math.floor(code / 65536) .. ':' .. code % 65536 .. ' goes to ' .. id .. ': ' ..
             previous .. ' has not registered for ' .. (book.session - book.bindings[previous].seen - 1) ..
             ' sessions; its keys are cleared.')
        book.bindings[previous] = nil
        book.actions[code] = {clear = true}
    end
    local own = book.bindings[id]
    if own and book.holders[own.code] == id then book.holders[own.code] = nil end
    book.bindings[id], book.holders[code] = {code = code, seen = book.session}, id
    book.dirty = true
    return code
end

-- Why no action is left: reservations of mods not loaded this session, or
-- every automatic action in use. Logged once per id.
local function refuse(book, id)
    local reason = REASON_FULL
    for index = SLOTS + 1, #DORMANT_ACTIONS do
        local code = auto_code(index)
        if not state.used[code] and book.holders[code] then reason = REASON_RESERVED end
    end
    if not state.refused[id] then
        state.refused[id] = true
        note('Cannot register ' .. id .. ': ' .. reason .. '.')
    end
    return reason
end

-- The automatic action for id, or nil and the reason.
local function assign_action(id)
    local book = load_assignments()
    count_session(book)
    local own = book.bindings[id]
    if own and not state.used[own.code] then
        if own.seen ~= book.session then own.seen, book.dirty = book.session, true end
        return own.code
    end
    local code = free_action(book) or expired_action(book)
    if code then return hand_over(book, id, code) end
    return nil, refuse(book, id)
end

mbm.load_assignments, mbm.flush_assignments, mbm.assign_action = load_assignments, flush_assignments, assign_action
