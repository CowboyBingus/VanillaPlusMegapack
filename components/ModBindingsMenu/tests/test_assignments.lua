-- The assignments file: saved through a temporary file and a backup, restored
-- from the backup after an interrupted save or damage, never rewritten
-- unchanged; a failed save keeps the assignments and logs once. Each binding
-- records the last session it registered in. A session counts from the first
-- time a mod asks for an automatic binding in it, and only if it saves (its
-- bindings work).
local here = arg[0]:match('^(.*[/\\])') or './'
local root = here .. '..'
local source = root .. '/src/mod_bindings_menu.lua'
local ffi = require('ffi')
ffi.cdef [[int mbm_test_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");]]
-- A folder of its own, so other tests' files never mix in.
local directory = assert(os.getenv('TEMP') or os.getenv('TMP')) .. '/mbm-test-assignments'
ffi.load('kernel32').mbm_test_CreateDirectoryA(directory, nil)
local path = directory .. '/ModBindingsMenu.assignments'
local backup, temporary = path .. '.bak', path .. '.tmp'
local function remove_files()
    for _, file in ipairs({path, backup, temporary}) do os.remove(file) end
end
local function read_file(name)
    local file = io.open(name, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end
local function write_file(name, text)
    local file = assert(io.open(name, 'wb'))
    assert(file:write(text))
    assert(file:close())
end
-- The text Mod Bindings Menu saves: session number, then the binding lines.
local function saved(session, ...)
    local lines = {'format 2', 'session ' .. session, ...}
    lines[#lines + 1] = 'end'
    return table.concat(lines, '\n') .. '\n'
end

local Text = dofile(root .. '/src/bingus_text.lua')
-- The other source files: the build places them ahead of the main file as
-- the functions in the local mbm_files; here mbm_files loads src/<name>.lua.
_G.mbm_files = setmetatable({}, {__index = function(files, name)
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
-- A fresh Mod Bindings Menu, as at the start of a game session, with its log.
-- end_session() is what the step of a session whose bindings work does: it
-- saves what changed. load() loads the assignments without registering.
local lines = {}
local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
local function session()
    _G.ModBindingsMenu, _G.BingusTranslations = nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
    _G.update, _G.BingusRuntime = function() end, nil
    dofile(source)
    local menu = ModBindingsMenu
    local step = upvalue(update, 'step')
    local flush = upvalue(step, 'flush_assignments')
    local load = upvalue(upvalue(upvalue(step, 'away_frame'), 'sweep_bindings'), 'load_assignments')
    local state = upvalue(menu.register_binding, 'state')
    local function end_session()
        if state.assignments and state.assignments.dirty then flush(0) end
    end
    return menu, state, flush, end_session, load
end
local function logged(text, from)
    local found = 0
    for index = from or 1, #lines do
        if lines[index]:find(text, 1, true) then found = found + 1 end
    end
    return found
end

-- Saving: format 2 with the session number and each binding's last session,
-- and its end line; the previous file becomes the backup; no temporary file
-- stays behind.
remove_files()
local menu, state, flush = session()
assert(menu.register_binding('save.a', 'A'))
assert(state.assignments.dirty and state.assignments.session == 1)
flush(0)
local first = read_file(path)
assert(first == saved(1, 'save.a\t10\t0\t1'), first)
assert(read_file(backup) == nil and read_file(temporary) == nil and not state.assignments.dirty)
assert(menu.register_binding('save.b', 'B'))
flush(0)
assert(read_file(path) == saved(1, 'save.a\t10\t0\t1', 'save.b\t10\t2\t1') and read_file(backup) == first)
assert(read_file(temporary) == nil)
-- Unchanged assignments are not written: nothing is opened for writing.
local real_open = io.open
local writes = 0
io.open = function(name, mode)
    if mode and mode:find('w', 1, true) then writes = writes + 1 end
    return real_open(name, mode)
end
state.assignments.dirty = true
flush(0)
assert(writes == 0 and not state.assignments.dirty, 'unchanged assignments written')
-- The next session saves once (its number and the bindings it saw), then not
-- again while nothing changes.
local again, again_state, again_flush, again_end = session()
assert(again.register_binding('save.a', 'A') and again_state.assignments.bindings['save.a'].code == 10 * 65536)
again_end()
assert(writes == 1 and read_file(path) == saved(2, 'save.a\t10\t0\t2', 'save.b\t10\t2\t1'))
again_state.assignments.dirty = true
again_flush(0)
io.open = real_open
assert(writes == 1, 'a save without changes rewrote the file')
print('Assignments saved through a temporary file and a backup; unchanged assignments not written OK')

-- Sessions. One on an unsupported game build does not count: it never saves,
-- although save.b registers in it.
local inert = session()
assert(inert.register_binding('save.b', 'B'))
-- Nor does one in which no mod asks for an automatic binding, even when it
-- saves something else (here a fixed slot's sweep record): the file keeps
-- session 2 and every reservation keeps its age.
local fixed, fixed_state, fixed_flush, _, fixed_load = session()
assert(fixed.register_binding('fixed.map', 0xb46c8096, 1))
local book = fixed_load()
book.actions[12 * 65536 + 1] = {cleared = book.session, found = 1, left = 2}
book.dirty = true
fixed_flush(0)
assert(not fixed_state.assignments.counted)
assert(read_file(path) == saved(2, 'save.a\t10\t0\t2', 'save.b\t10\t2\t1', 'action 12:1 cleared 3 found 00000001 left 00000002'),
       'a session without an automatic binding keeps the session number')
-- A session whose first automatic registration comes late counts, once: an
-- early save keeps session 2, the late registration makes it session 3, and
-- a later one changes only its own line.
local late, late_state, late_flush, _, late_load = session()
book = late_load()
book.actions[12 * 65536 + 1].left = 3
book.dirty = true
late_flush(0)
assert(read_file(path):find('^format 2\nsession 2\n'), 'saved before any automatic registration: not counted yet')
assert(late.register_binding('save.b', 'B') and late_state.assignments.counted)
late_flush(0)
assert(read_file(path) == saved(3, 'save.a\t10\t0\t2', 'save.b\t10\t2\t3', 'action 12:1 cleared 3 found 00000001 left 00000003'))
assert(late.register_binding('save.c', 'C') and late_state.registry['save.c'].code == 10 * 65536 + 3)
late_flush(0)
assert(read_file(path) == saved(3, 'save.a\t10\t0\t2', 'save.b\t10\t2\t3', 'save.c\t10\t3\t3',
                                'action 12:1 cleared 3 found 00000001 left 00000003'), 'counted once')
-- With no automatic binding at all, nothing is loaded and nothing written.
remove_files()
local _, empty_state, _, empty_end = session()
empty_end()
assert(read_file(path) == nil and empty_state.assignments == nil, 'nothing to save, nothing written')
-- A v2.1 file (binding lines only) loads complete; its bindings count as seen
-- in session 0, so each keeps its action for the next 30 sessions.
write_file(path, 'legacy.b\t10\t2\nlegacy.a\t10\t0\n')
local legacy, legacy_state, _, legacy_end = session()
assert(legacy_state.assignments == nil and legacy.register_binding('legacy.a', 'A'))
assert(legacy_state.registry['legacy.a'].code == 10 * 65536 and legacy_state.assignments.session == 1)
assert(legacy_state.assignments.bindings['legacy.b'].seen == 0)
legacy_end()
assert(read_file(path) == saved(1, 'legacy.a\t10\t0\t1', 'legacy.b\t10\t2\t0'))
print('Sessions: each binding saves its last session; a session counts once from its first automatic registration, '
      .. 'late or not; inert sessions and sessions without one keep every age; v2.1 files load OK')

-- Interrupted saves, as each crash leaves the folder, then a new session.
local old = saved(4, 'kept.a\t10\t0\t4', 'kept.b\t10\t2\t4')
-- 1. Crashed while writing the temporary file or before setting the old file
--    aside: the old file is complete and is used.
remove_files()
write_file(path, old)
write_file(temporary, old:sub(1, 20))
local _, st = session()
local from = #lines + 1
assert(ModBindingsMenu.register_binding('kept.b', 'B') and st.registry['kept.b'].code == 10 * 65536 + 2)
assert(st.assignments.bindings['kept.a'].code == 10 * 65536 and st.assignments.session == 5)
assert(logged('restored', from) == 0 and not st.assignments.damaged)
-- 2. Crashed between the renames: only the backup and the temporary file. The
--    backup is used, and the next save writes the file back.
remove_files()
write_file(backup, old)
write_file(temporary, saved(5, 'kept.a\t10\t0\t5'))
local menu2, st2, flush2 = session()
from = #lines + 1
assert(menu2.register_binding('kept.a', 'A') and st2.registry['kept.a'].code == 10 * 65536)
assert(logged('restored from ModBindingsMenu.assignments.bak; the file was missing.', from) == 1)
assert(st2.assignments.dirty and not st2.assignments.damaged and st2.assignments.session == 5)
flush2(0)
assert(read_file(path) == saved(5, 'kept.a\t10\t0\t5', 'kept.b\t10\t2\t4'))
assert(read_file(backup) == old and read_file(temporary) == nil)
-- 3. A damaged file (cut short: format 2 without its end line) next to a good
--    backup: the backup is used, and the next save replaces the damaged file
--    without moving it over the good backup.
remove_files()
write_file(path, 'format 2\nsession 5\nkept.a\t10\t0\t5\nkep')
write_file(backup, old)
local menu3, st3, flush3 = session()
from = #lines + 1
assert(menu3.register_binding('kept.b', 'B') and st3.registry['kept.b'].code == 10 * 65536 + 2)
assert(logged('the file was damaged.', from) == 1 and st3.assignments.damaged)
assert(menu3.register_binding('kept.c', 'C') and st3.registry['kept.c'].code == 10 * 65536 + 3)
flush3(0)
assert(read_file(path) == saved(5, 'kept.a\t10\t0\t4', 'kept.b\t10\t2\t5', 'kept.c\t10\t3\t5'))
assert(read_file(backup) == old, 'the good backup survives the repair')
-- 4. A damaged file and no backup: logged, and automatic bindings start over.
remove_files()
write_file(path, 'format 2\nsession 5\nkept.a\t10\t0\t5\n')
local menu4, st4 = session()
from = #lines + 1
assert(menu4.register_binding('fresh.a', 'A') and st4.registry['fresh.a'].code == 10 * 65536)
assert(logged('damaged and has no backup', from) == 1)
print('Interrupted saves: the complete file, else the backup; a damaged file never replaces a good backup OK')

-- Failed saves keep the assignments dirty and log once; the save is tried
-- again a minute later and succeeds once the disk does.
remove_files()
write_file(path, old)
local menu6, st6, flush6 = session()
assert(menu6.register_binding('kept.c', 'C'))
local new = saved(5, 'kept.a\t10\t0\t4', 'kept.b\t10\t2\t4', 'kept.c\t10\t3\t5')
local failure = 'write'
io.open = function(name, mode)
    if name ~= temporary or not mode or not mode:find('w', 1, true) then return real_open(name, mode) end
    if failure == 'open' then return nil, temporary .. ': Permission denied' end
    local file = assert(real_open(name, mode))
    return {
        write = function(_, text)
            if failure == 'write' then return nil, 'No space left on device' end
            return file:write(text)
        end,
        close = function()
            local closed = file:close()
            if failure == 'close' then return nil, 'Input/output error' end
            return closed
        end,
    }
end
from = #lines + 1
flush6(0)
assert(st6.assignments.dirty and st6.assignments.failed and read_file(path) == old and read_file(temporary) == nil)
assert(logged('Cannot save binding assignments (No space left on device)', from) == 1)
flush6(30)
flush6(30)
failure = 'close'
flush6(0)
assert(st6.assignments.dirty and read_file(path) == old, 'a failed close is a failed save')
failure = 'open'
flush6(60)
flush6(0)
assert(st6.assignments.dirty and read_file(path) == old and logged('Cannot save', from) == 1, 'logged once')
-- The final rename fails: the old file goes back in place.
io.open = real_open
local real_rename = os.rename
os.rename = function(a, b)
    if a == temporary then return nil, 'Access is denied' end
    return real_rename(a, b)
end
flush6(60)
flush6(0)
os.rename = real_rename
assert(st6.assignments.dirty and read_file(path) == old and read_file(temporary) == nil)
assert(logged('Cannot save', from) == 1)
flush6(60)
flush6(0)
assert(not st6.assignments.dirty and not st6.assignments.failed and read_file(path) == new)
assert(logged('Saved binding assignments after an earlier failure.', from) == 1)
remove_files()
print('Failed saves (open, write, close, rename) keep the assignments, log once and retry a minute later OK')
