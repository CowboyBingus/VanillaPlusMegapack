-- The extended bindings file (src/extended_store.lua): data-only parsing,
-- a damaged file replaced by its backup or set aside (never overwritten), a
-- file of a newer format left untouched with its bindings inactive, lines this
-- version cannot read kept verbatim with their binding inactive, interrupted
-- and failed saves.
-- Usage: luajit test_extended_store.lua [path to src/mod_bindings_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local ffi = require('ffi')
ffi.cdef [[int mbm_test_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");]]
local directory = assert(os.getenv('TEMP') or os.getenv('TMP')) .. '/mbm-test-extended-store'
ffi.load('kernel32').mbm_test_CreateDirectoryA(directory, nil)
local path = directory .. '/ModBindingsMenu.bindings'
local backup, temporary, damaged = path .. '.bak', path .. '.tmp', path .. '.damaged'
local function remove_files()
    for _, name in ipairs({path, backup, temporary, damaged, directory .. '/ModBindingsMenu.assignments',
                           directory .. '/ModBindingsMenu.assignments.bak'}) do
        os.remove(name)
    end
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

local Text = dofile(root .. '/src/bingus_text.lua')
_G.mbm_files = setmetatable({}, {__index = function(loaded, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(loaded, name, chunk)
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
-- A simulated keyboard: G is button 3, held when held_g is true.
local held_g = false
_G.stingray = {Keyboard = {button = function(index) return index == 3 and held_g and 1 or 0 end,
                           button_id = function(name) return ({g = 3, f9 = 1})[name] end,
                           button_name = function(index) return ({[3] = 'g', [1] = 'f9'})[index] end}}
-- A fresh Mod Bindings Menu, as at the start of a game session, with its log.
local lines = {}
local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
local function session()
    _G.ModBindingsMenu, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
    _G.update = function() end
    dofile(source)
    local menu = ModBindingsMenu
    local step = upvalue(update, 'step')
    local state = upvalue(menu.register_binding, 'state')
    return menu, state, upvalue(step, 'flush_extended')
end
local function logged(text)
    for _, line in ipairs(lines) do if line:find(text, 1, true) then return true end end
    return false
end
local EXTENDED = {backend = 'extended'}
-- Whether G presses id: one frame to record, one with G held.
local function g_presses(menu, state, id)
    state.frame = state.frame + 1
    menu.is_down(id)
    held_g = true
    state.frame = state.frame + 1
    local down = menu.is_down(id)
    held_g = false
    state.frame = state.frame + 1
    menu.is_down(id)
    return down
end

-- Saving: format 1, sorted by id, the end line; the previous file becomes the
-- backup; unchanged stores are not written.
remove_files()
local menu, state, flush = session()
assert(menu.register_binding('a.one', 'One', nil, EXTENDED) and menu.register_binding('b.two', 'Two', nil, EXTENDED))
flush(0)
assert(read_file(path) == 'format 1\na.one\tdefault\nb.two\tdefault\nend\n', read_file(path))
assert(menu.set_binding('b.two', {'g'}))
flush(0)
assert(read_file(path) == 'format 1\na.one\tdefault\nb.two\tset\tk:3@press\nend\n')
assert(read_file(backup) == 'format 1\na.one\tdefault\nb.two\tdefault\nend\n' and read_file(temporary) == nil)
local real_open, writes = io.open, 0
io.open = function(name, mode)
    if mode and mode:find('w', 1, true) then writes = writes + 1 end
    return real_open(name, mode)
end
state.extended_store.dirty = true
flush(0)
io.open = real_open
assert(writes == 0, 'an unchanged store was written')
print('Saved through a temporary file and a backup, sorted, unchanged stores not written OK')

-- Interrupted between the renames: the new file is still the temporary one and
-- the backup holds the previous save (b.two on its default). The backup is
-- used and written back.
os.rename(path, temporary)
menu, state, flush = session()
assert(menu.register_binding('b.two', 'Two', nil, EXTENDED))
assert(menu.binding_info('b.two').state == 'default' and logged('restored from ModBindingsMenu.bindings.bak'))
os.remove(temporary)
flush(0)
assert(read_file(path) and read_file(path):find('b.two\tdefault', 1, true), 'written back from the backup')

-- Damaged (no end line) with a usable backup: the backup is used, and the next
-- save replaces the damaged file without moving it over the good backup.
write_file(path, 'format 1\nb.two\tset\tk:3@pr')
write_file(backup, 'format 1\nb.two\tset\tk:3@press\nend\n')
menu, state, flush = session()
assert(menu.register_binding('b.two', 'Two', nil, EXTENDED) and menu.binding_info('b.two').state == 'set')
assert(g_presses(menu, state, 'b.two'), 'the backup\'s G')
flush(0)
assert(read_file(backup) == 'format 1\nb.two\tset\tk:3@press\nend\n', 'the good backup is kept')
assert(read_file(path) == 'format 1\nb.two\tset\tk:3@press\nend\n')
print('An interrupted save and a damaged file: the backup is used and written back OK')

-- Damaged without a usable backup: it is set aside as .damaged before the next
-- save, never overwritten, and bindings start from their defaults.
remove_files()
write_file(path, 'not a bindings file')
menu, state, flush = session()
assert(menu.register_binding('b.two', 'Two', nil, {backend = 'extended', default = 'f9'}))
assert(menu.binding_info('b.two').state == 'default' and logged('kept as ModBindingsMenu.bindings.damaged'))
flush(0)
assert(read_file(damaged) == 'not a bindings file' and read_file(path) == 'format 1\nb.two\tdefault\nend\n')
-- A later damaged file without backup, while .damaged exists: its own name.
remove_files()
write_file(damaged, 'earlier')
write_file(path, 'format 1\nunfinished')
menu, state, flush = session()
assert(menu.register_binding('b.two', 'Two', nil, EXTENDED))
flush(0)
assert(read_file(damaged) == 'earlier' and read_file(path) == 'format 1\nb.two\tdefault\nend\n')
local found_own = false
for name in io.popen('dir /b "' .. directory:gsub('/', '\\') .. '"'):lines() do
    if name:find('^ModBindingsMenu%.bindings%.damaged%-%d+$') then
        found_own = true
        os.remove(directory .. '/' .. name)
    end
end
assert(found_own, 'the second damaged file is kept under a name of its own')
print('A damaged file without backup is set aside, never overwritten OK')

-- A newer format: left exactly as it is, every extended binding inactive
-- (false), set_binding refused, nothing written.
remove_files()
write_file(path, 'format 2\nb.two\tnewverb\tsomething\nend\n')
menu, state, flush = session()
assert(menu.register_binding('b.two', 'Two', nil, {backend = 'extended', default = 'g'}))
assert(menu.binding_info('b.two').state == 'inactive' and not g_presses(menu, state, 'b.two'))
assert(select(2, menu.set_binding('b.two', {'g'})) == 'the bindings file is from a newer version')
state.extended_store.dirty = true
flush(0)
assert(read_file(path) == 'format 2\nb.two\tnewverb\tsomething\nend\n' and read_file(backup) == nil)
assert(logged('written by a newer Mod Bindings Menu'))
print('A newer format is left untouched; its bindings stay inactive OK')

-- Lines this version cannot read: kept verbatim, their binding inactive and
-- never replaced by the default; other bindings work.
remove_files()
write_file(path, 'format 1\nb.two\tset\tq:7@press\nc.three\tset\tk:3@tap\nd.four\tset\tk:3@press\nend\n')
menu, state, flush = session()
for _, id in ipairs({'b.two', 'c.three', 'd.four'}) do
    assert(menu.register_binding(id, id, nil, {backend = 'extended', default = 'g'}))
end
assert(menu.binding_info('b.two').state == 'inactive' and menu.binding_info('c.three').state == 'inactive')
assert(not g_presses(menu, state, 'b.two') and not g_presses(menu, state, 'c.three'))
assert(g_presses(menu, state, 'd.four'))
assert(menu.set_binding('d.four', {}))
flush(0)
assert(read_file(path) == 'format 1\nb.two\tset\tq:7@press\nc.three\tset\tk:3@tap\nd.four\tcleared\nend\n',
       read_file(path))
print('Unreadable lines are kept verbatim and their bindings stay inactive OK')

-- Failed saves (open refused): the change stays, the page sees why, logged
-- once, tried again after a minute.
remove_files()
menu, state, flush = session()
assert(menu.register_binding('b.two', 'Two', nil, EXTENDED))
io.open = function(name, mode)
    if mode == 'wb' then return nil, 'refused' end
    return real_open(name, mode)
end
local before = #lines
flush(0)
assert(state.save_problem == 'refused' and state.extended_store.dirty and state.extended_store.retry == 60)
flush(30)
flush(30)
assert(#lines == before + 1, 'logged once')
io.open = real_open
flush(1)
assert(state.save_problem == nil and not state.extended_store.dirty and read_file(path))
assert(logged('Saved extended bindings after an earlier failure.'))
print('A failed save keeps the change, shows why, logs once and retries a minute later OK')

-- Malformed values never reach the bindings: devices, triggers and indexes out
-- of range, too many inputs or alternatives; parsing never runs the file.
remove_files()
local many = {}
for index = 1, 17 do many[index] = 'k:3@press' end
write_file(path, table.concat({'format 1', 'a\tset\tk:70000@press', 'b\tset\tk:3+k:1+k:2+k:4+k:5+k:6@press',
                               'c\tset\t' .. table.concat(many, '|'), 'd\tset\t@press', 'e\tset\tk:3@press|',
                               'f\tset\tk:x@press', 'g\tset\tos.exit()', 'end'}, '\n') .. '\n')
menu, state = session()
for _, id in ipairs({'a', 'b', 'c', 'd', 'e', 'f', 'g'}) do
    assert(menu.register_binding(id, id, nil, EXTENDED))
    assert(menu.binding_info(id).state == 'inactive', id)
end
print('Malformed values are kept as unreadable lines, inactive OK')
remove_files()
