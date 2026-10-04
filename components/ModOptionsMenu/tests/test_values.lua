-- The values file (ModOptionsMenu.values): what is written, and when.
-- Usage: <lua> tests/test_values.lua [path to src/mod_options_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_options_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local PATH = directory .. '/ModOptionsMenu.values'
local ffi = require('ffi')
local Text = dofile(root .. '/src/bingus_text.lua')
_G.mom_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
_G.mom_files = setmetatable({}, {__index = function(files, name)
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
local function read(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end
local function write(path, text)
    local file = assert(io.open(path, 'wb'))
    assert(file:write(text))
    assert(file:close())
end
local function clean()
    for _, suffix in ipairs({'', '.tmp', '.bak'}) do os.remove(PATH .. suffix) end
end
-- Opens of the values file for writing.
local writes = 0
local real_open, real_rename, real_remove = io.open, os.rename, os.remove
local function counting_open(path, mode)
    if mode == 'wb' and tostring(path):find('ModOptionsMenu.values', 1, true) then writes = writes + 1 end
    return real_open(path, mode)
end
io.open = counting_open
local lines = {}
local function count(text)
    local found = 0
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then found = found + 1 end
    end
    return found
end
-- A new instance without a menu, with two options from the values file.
local function fresh()
    _G.ModOptionsMenu, _G.update, _G.BingusTranslations, _G.BingusRuntime = nil, function() end, nil, nil
    Text.registry().steam_language = 'en'
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function()
        return {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    end}
    dofile(source)
    local menu = assert(ModOptionsMenu)
    assert(menu.register_option('a.toggle', {type = 'toggle', label = 'Toggle', mod = 'Values Test'}))
    assert(menu.register_option('a.slider', {type = 'slider', label = 'Slider', mod = 'Values Test', min = 0, max = 1,
                                             step = 0.05}))
    local step = upvalue(update, 'step')
    return menu, upvalue(menu.register_option, 'state'), upvalue(step, 'save_values'), step
end
local ORIGINAL = 'a.slider\t0.5\na.toggle\ttrue\nother.mod\t7\n'
local CHANGED = 'a.slider\t0.75\na.toggle\ttrue\nother.mod\t7\n'

-- Unchanged values are not written: set() with the value an option already has
-- leaves the file alone, and so does a save whose text the file already holds
-- (a value set and set back before the save). The values of options not
-- registered this session are kept.
do
    clean()
    write(PATH, ORIGINAL)
    local menu, state, save_values = fresh()
    assert(menu.get('a.toggle') == true and menu.get('a.slider') == 0.5 and state.written == ORIGINAL)
    writes = 0
    for _ = 1, 3 do assert(menu.set('a.toggle', true) and menu.set('a.slider', 0.5)) end
    assert(not state.dirty and writes == 0, 'set() with an unchanged value marks nothing to save')
    assert(menu.set('a.slider', 0.75) and state.dirty and menu.set('a.slider', 0.5))
    save_values()
    assert(not state.dirty and writes == 0 and read(PATH) == ORIGINAL, 'a value set back is not written')
    assert(menu.set('a.slider', 0.75) and state.dirty)
    save_values()
    assert(not state.dirty and writes == 1 and read(PATH) == CHANGED)
    assert(menu.set('a.slider', 0.75) and not state.dirty and writes == 1)
    save_values()
    assert(writes == 1, 'nothing changed since the last save')
end
print('PASS: unchanged values are not written: set() with the current value marks nothing, and a save whose text '
      .. 'the file already holds is skipped; values of other mods are kept')

-- A save goes through ModOptionsMenu.values.tmp; the old file becomes the
-- backup, and no temp file stays.
do
    clean()
    write(PATH, ORIGINAL)
    local menu, state, save_values = fresh()
    assert(menu.set('a.slider', 0.75))
    save_values()
    assert(not state.dirty and read(PATH) == CHANGED and read(PATH .. '.bak') == ORIGINAL and not read(PATH .. '.tmp'))
end

-- Loading falls back to the backup when the file is missing, unreadable or
-- holds no value, and the next save writes the file again.
do
    for _, case in ipairs({'missing', 'empty', 'unreadable'}) do
        clean()
        write(PATH .. '.bak', ORIGINAL)
        if case == 'empty' then write(PATH, '') end
        if case == 'unreadable' then
            write(PATH, CHANGED)
            io.open = function(path, mode)
                if path == PATH and mode == 'rb' then return nil, 'injected: unreadable' end
                return counting_open(path, mode)
            end
        end
        local before = count('read from the backup')
        local menu, state, save_values = fresh()
        io.open = counting_open
        assert(menu.get('a.slider') == 0.5 and state.saved['other.mod'] == '7', case .. ' file: the backup is read')
        assert(count('read from the backup') == before + 1 and state.written == nil)
        state.dirty = true
        save_values()
        assert(read(PATH) == ORIGINAL and not state.dirty, case .. ' file: the next save writes it')
    end
end
print('PASS: a save writes a temp file, keeps the old file as the backup and moves the temp file into place; '
      .. 'loading falls back to the backup when the file is missing, empty or unreadable')

-- File operations fail or the game stops on demand: on_operation(number, name)
-- sees each operation of a save in order (1 open the temp file, 2 write, 3
-- close, 4 remove the old backup, 5 rename the file to the backup, 6 rename the
-- temp file into place, then any cleanup) and returns 'fail' to make it fail.
-- opened.file: the last real file opened for writing, closed by restore() as
-- the system would close it.
local opened = {}
local function inject(on_operation)
    local number = 0
    local function operation(name)
        number = number + 1
        return on_operation(number, name) == 'fail'
    end
    io.open = function(path, mode)
        if mode ~= 'wb' then return counting_open(path, mode) end
        number = 0 -- each save opens its temp file first
        if operation('open') then return nil, 'injected: cannot open' end
        local file = assert(counting_open(path, mode))
        opened.file = file
        return {write = function(_, ...)
                    if operation('write') then return nil, 'injected: disk full' end
                    return file:write(...)
                end,
                close = function()
                    local fail = operation('close')
                    local closed, reason = file:close()
                    if fail then return nil, 'injected: cannot close' end
                    return closed, reason
                end}
    end
    os.rename = function(from, to)
        if operation('rename') then return nil, 'injected: cannot rename' end
        return real_rename(from, to)
    end
    os.remove = function(path)
        if operation('remove') then return nil, 'injected: cannot remove' end
        return real_remove(path)
    end
end
local function restore()
    io.open, os.rename, os.remove = counting_open, real_rename, real_remove
    if opened.file and io.type(opened.file) == 'file' then opened.file:close() end
    opened.file = nil
end
-- What a new session reads: complete old or new values, nothing else.
local function next_session_reads()
    local menu, state = fresh()
    assert(state.saved['other.mod'] == '7' and menu.get('a.toggle') == true, 'a value was lost')
    return menu.get('a.slider')
end

-- Interrupted save: the game stops before each of the save's file operations
-- in turn (the save never resumes). The next session reads the old values or,
-- after the last operation, the new ones; never a part of the file.
do
    local stops = 0
    for stop = 1, 7 do
        clean()
        write(PATH, ORIGINAL)
        local menu, _, save_values = fresh()
        assert(menu.set('a.slider', 0.75))
        inject(function(number) if number == stop then coroutine.yield() end end)
        local save = coroutine.create(save_values)
        assert(coroutine.resume(save))
        local stopped = coroutine.status(save) == 'suspended'
        restore()
        if stopped then stops = stops + 1 end
        assert(next_session_reads() == (stopped and 0.5 or 0.75), 'interrupted before operation ' .. stop)
    end
    assert(stops == 6, 'a save makes six file operations')
end
print('PASS: an interrupted save (the game stopping before any of its six file operations) leaves the old values '
      .. 'for the next session, read from the file or its backup')

-- Failed save: whichever file operation fails, the file keeps the old values or
-- holds the new ones, no temp file stays, and a save that did not happen leaves
-- the values due. The first failure after a save that worked is logged once.
do
    for fail = 1, 6 do
        clean()
        write(PATH, ORIGINAL)
        local menu, state, save_values = fresh()
        assert(menu.set('a.slider', 0.75))
        local before = count('Cannot save option values')
        inject(function(number) if number == fail then return 'fail' end end)
        save_values()
        save_values()
        restore()
        local text = read(PATH)
        assert(text == ORIGINAL or text == CHANGED, 'a failed save damaged the file')
        assert(state.dirty == (text ~= CHANGED) and not read(PATH .. '.tmp'), 'operation ' .. fail)
        assert(count('Cannot save option values') == before + (state.dirty and 1 or 0), 'logged once')
        if state.dirty then
            save_values()
            assert(read(PATH) == CHANGED and not state.dirty and not state.save_failed, 'saved once it can be')
            assert(menu.set('a.slider', 0.25))
            inject(function() return 'fail' end)
            save_values()
            restore()
            assert(state.dirty and count('Cannot save option values') == before + 2, 'a new failure is logged')
        end
    end
end
print('PASS: whichever file operation fails, the old values stay in the file, no temp file stays, the values stay '
      .. 'due and the failure is logged once')

-- Retries: a failed save tries again after 10 seconds of frames, not every
-- frame, also with the escape menu closed. The menu is closed here: the UI
-- state pointer MOM reads from game.dll (at base + 0x347ce28) is null.
do
    clean()
    write(PATH, ORIGINAL)
    local menu, state, _, step = fresh()
    local ui_state = ffi.new('uint64_t[1]', 0)
    state.initialized, state.native = true, {}
    state.base = tonumber(ffi.cast('uint64_t', ui_state)) - 0x347ce28
    assert(menu.set('a.slider', 0.75))
    local attempts = 0
    inject(function(_, name)
        if name == 'open' then attempts = attempts + 1 end
        return 'fail'
    end)
    for _ = 1, 250 do step(0.1) end -- 25 seconds
    restore()
    assert(attempts == 3 and state.dirty and read(PATH) == ORIGINAL, 'tries at 1, 11 and 21 seconds: ' .. attempts)
    for _ = 1, 100 do step(0.1) end
    assert(not state.dirty and read(PATH) == CHANGED, 'saved at 31 seconds')
end
print('PASS: a failed save tries again 10 seconds later, not every frame')
clean()
