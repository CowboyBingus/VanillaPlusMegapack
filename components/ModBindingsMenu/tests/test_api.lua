-- Exercise the public registration contract without a running game.
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
-- Keep automatic assignments away from the user's real settings directory.
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local assignments = directory .. '/ModBindingsMenu.assignments'
-- The assignments file, its backup and an interrupted save's temporary file.
local function remove_assignments()
    for _, suffix in ipairs({'', '.bak', '.tmp'}) do os.remove(assignments .. suffix) end
end
remove_assignments()
_G.CowboyBingusModLoader = {log_directory = directory}
-- The build puts the text module and the locales ahead of the main file as
-- the local mbm_text; here it is a global.
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local Text = dofile(root .. '/src/bingus_text.lua')
_G.BingusTranslations = nil
Text.registry().steam_language = 'en'
_G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
-- The other source files: the build places them ahead of the main file as
-- the functions in the local mbm_files; here mbm_files loads src/<name>.lua.
_G.mbm_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})
-- The game's update, which the menu's guard wraps.
_G.update = function() end
dofile(source)

local host = assert(ModBindingsMenu)
assert(host.api == 1 and not host.ready() and host.revision == 0)
local function upvalue(fn, wanted)
    for index = 1, 60 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local state = upvalue(host.register_binding, 'state')
local step = upvalue(update, 'step')
local initialize = upvalue(step, 'initialize')
local dormant = upvalue(initialize, 'DORMANT_ACTIONS')
assert(#dormant == 36 and host.capacity == 36)
assert(dormant[3][3] == 0x6218a8ba and dormant[4][3] == 0xd46660e4)
local seen = {}
for _, entry in ipairs(dormant) do
    local code = entry[1] * 65536 + entry[2]
    assert(not seen[code] and entry[1] >= 9 and entry[1] <= 12 and entry[2] < 97)
    seen[code] = true
end

-- The step saves changed assignments; here a session saves them when it ends.
-- A session counts once a mod asks for an automatic binding in it.
local flush_assignments = upvalue(step, 'flush_assignments')
local function save()
    if state.assignments and state.assignments.dirty then flush_assignments(0) end
end
local function reset_registry()
    for _, field in ipairs({'registry', 'used', 'refused'}) do
        for key in pairs(state[field]) do state[field][key] = nil end
    end
    for index = #state.order, 1, -1 do state.order[index] = nil end
    state.assignments = nil
end
-- The next game session: this one counts and is saved, then nothing is registered.
local function new_session()
    save()
    reset_registry()
end
-- Actions whose keys are to be cleared entirely (handed over from an expired binding).
local function queued_clears()
    local queued = 0
    for _, action in pairs(state.assignments.actions) do
        if action.clear then queued = queued + 1 end
    end
    return queued
end
-- The reasons register_binding gives when no automatic action is left.
local RESERVED = 'no free binding action; the others are reserved by mods not loaded this session'
local FULL = 'all 29 automatic binding actions in use'

local registrations = {
    {'map', 0xb46c8096, 1, 12, 1},
    {'external', 0x3ef7f7ad, 2, 12, 0},
    {'armory', 0x19e97f02, 3, 10, 1},
    {'control', 'CONTROL CENTER', 4, 10, 4},
    {'management', 0x2716885e, 5, 10, 8},
    {'arcade', 'STRATAGEM HERO', 6, 10, 14},
    {'hellpod', 0xe89a91ef, 7, 10, 9},
}
for _, row in ipairs(registrations) do
    assert(host.register_binding(row[1], row[2], row[3]))
    local record = state.registry[row[1]]
    assert(record.group == row[4] and record.action == row[5] and record.slot == row[3])
    assert(host.is_down(row[1]) == nil)
end
assert(#state.order == 7)
assert(host.register_binding('external', 0x3ef7f7ad, 2))
assert(not host.register_binding('control', 0x3ef7f7ad, 4))
assert(not host.register_binding('control', 0x3ef7f7ad, 5))
assert(state.registry.control.text == 'CONTROL CENTER')
assert(state.registry.arcade.text == 'STRATAGEM HERO')
-- version 3: texts may be functions; version 4: extended bindings. api stays 1.
assert(host.version == 4 and host.api == 1)
-- Callers outside a mods/<author>/<entry> resource fall back to MODS.
assert(state.registry.map.category == 'MODS')
-- revision grows by one per binding registered; a repeated or refused
-- registration leaves it as it is.
assert(host.revision == 7 and host.revision == state.revision)
assert(host.register_binding('external', 0x3ef7f7ad, 2) and host.revision == 7)
assert(not host.register_binding('control', 0x3ef7f7ad, 5) and host.revision == 7)
print('Seven fixed slot registrations OK')

-- A second v1.1 addon asking for slot 2 gets an automatic action instead.
assert(host.register_binding('other', 0x3ef7f7ad, 2))
assert(state.registry.other.slot == nil and state.registry.other.group == 10
       and state.registry.other.action == 0)
assert(host.register_binding('other', 0x3ef7f7ad, 2))
assert(host.register_binding('new', 'FREE TEXT', 2))
assert(state.registry.new.action == 2)
-- Version 2 automatic registrations (nil or 0) fill the remaining actions.
assert(host.register_binding('auto_a', 'Auto A'))
assert(host.register_binding('auto_b', 'Auto B', 0))
assert(state.registry.auto_a.code == 10 * 65536 + 3)
assert(state.registry.auto_b.code == 10 * 65536 + 5)
assert(host.register_binding('auto_b', 'Auto B'))
assert(not host.register_binding('auto_b', 'Auto B', 3))
assert(not host.register_binding('tab\tid', 'Bad'))
print('Slot 2 overflow and automatic assignment OK')

-- Assignments persist: in a later session the same ids get the same actions,
-- whatever order the addons load in.
save()
local file = assert(io.open(assignments, 'rb'))
local saved = file:read('*a')
file:close()
assert(saved:find('^format 2\nsession 1\n') and saved:find('\nend\n$'), saved)
assert(saved:find('auto_a\t10\t3\t1\n', 1, true) and saved:find('other\t10\t0\t1\n', 1, true))
new_session()
assert(host.register_binding('auto_b', 'Auto B'))
assert(host.register_binding('auto_a', 'Auto A'))
assert(state.registry.auto_a.code == 10 * 65536 + 3)
assert(state.registry.auto_b.code == 10 * 65536 + 5)
-- A new id takes a free action, never one reserved for a binding absent (or
-- late) this session.
assert(host.register_binding('fresh', 'Fresh'))
assert(state.registry.fresh.code == 10 * 65536 + 6)
print('Persistent automatic assignments OK')

-- 29 automatic actions in total. The two reserved for 'other' and 'new', which
-- have not registered this session, stay theirs: the fill stops two short and
-- says why. Nothing is queued for clearing.
-- The pool's refusals stay for addons that ask for a native action only
-- (version 4: otherwise the registration gets an extended binding).
local NATIVE = {backend = 'native'}
local count, reason = 3, nil -- auto_a, auto_b and fresh are registered in this session.
while true do
    local ok, why = host.register_binding('fill_' .. count, 'Fill', nil, NATIVE)
    if not ok then
        reason = why
        break
    end
    count = count + 1
end
assert(count == 27 and reason == RESERVED, count .. ' ' .. tostring(reason))
assert(state.assignments.bindings.other.code == 10 * 65536 and state.assignments.bindings.new.code == 10 * 65536 + 2)
assert(queued_clears() == 0, 'no keys queued for clearing')
-- Late in the session they register and get their own actions.
assert(host.register_binding('other', 0x3ef7f7ad) and state.registry.other.code == 10 * 65536)
assert(host.register_binding('new', 'FREE TEXT') and state.registry.new.code == 10 * 65536 + 2)
-- Every automatic action is now used by a binding registered this session.
local ok, why = host.register_binding('overflow', 'Overflow', nil, NATIVE)
assert(not ok and why == FULL, tostring(why))
assert(select(2, host.register_binding('overflow', 'Overflow', nil, NATIVE)) == FULL)
print('Reservations: absent and late bindings keep their actions; a full pool says why OK')

-- The audit's reproduction (mod family audit 2026-10-03): fill the 29
-- automatic actions, restart, replace only the final binding with a new one
-- and register the new binding first. v2.1 moved all 28 retained bindings to
-- other actions and queued 29 actions for clearing.
reset_registry()
remove_assignments()
for index = 1, 29 do assert(host.register_binding('repro_' .. index, 'Repro ' .. index)) end
local held = {}
for index = 1, 29 do held[index] = state.registry['repro_' .. index].code end
new_session()
ok, why = host.register_binding('replacement', 'Replacement', nil, NATIVE)
assert(not ok and why == RESERVED, tostring(why))
for index = 1, 28 do
    assert(host.register_binding('repro_' .. index, 'Repro ' .. index))
    assert(state.registry['repro_' .. index].code == held[index], 'repro_' .. index .. ' moved')
end
assert(queued_clears() == 0, 'nothing of theirs is queued for clearing')
assert(state.assignments.bindings.repro_29.code == held[29], 'the absent binding keeps its reservation')
ok, why = host.register_binding('replacement', 'Replacement', nil, NATIVE)
assert(not ok and why == RESERVED)
print('Audit reproduction: the new binding registered first takes no reserved action; all 28 retained bindings ' ..
      'keep theirs and nothing is cleared OK')

-- A reservation ends once its binding has not registered for 30 sessions that
-- count. The next new binding then gets the action, and its old keys are
-- queued for clearing. Launches in which no mod asks for an automatic binding
-- (here only a fixed slot registers) do not count.
for session = 3, 31 do
    new_session()
    assert(host.register_binding('fixed', 0xb46c8096, 1) and state.assignments == nil)
    new_session()
    for index = 1, 28 do assert(host.register_binding('repro_' .. index, 'Repro ' .. index)) end
    ok, why = host.register_binding('replacement', 'Replacement', nil, NATIVE)
    assert(not ok and why == RESERVED and state.assignments.session == session, 'session ' .. session)
end
new_session()
for index = 1, 28 do assert(host.register_binding('repro_' .. index, 'Repro ' .. index)) end
assert(state.assignments.session == 32)
assert(host.register_binding('replacement', 'Replacement', nil, NATIVE))
assert(state.registry.replacement.code == held[29] and state.assignments.actions[held[29]].clear,
       'expired action handed over, its keys to be cleared')
assert(queued_clears() == 1)
assert(state.assignments.bindings.repro_29 == nil and state.assignments.holders[held[29]] == 'replacement')
-- The binding that expired comes back: a new id now, with every action in use.
ok, why = host.register_binding('repro_29', 'Repro 29', nil, NATIVE)
assert(not ok and why == FULL)
print('Reservations end after 30 sessions without their binding; the next new binding gets the action OK')

-- A refused automatic registration counts the session too: a mod refused for
-- reservations of mods that are gone gets an action once they expire, even
-- when it is the only binding mod left.
reset_registry()
remove_assignments()
for index = 1, 29 do assert(host.register_binding('gone_' .. index, 'Gone ' .. index)) end
local first_action = state.registry.gone_1.code
for session = 2, 31 do
    new_session()
    ok, why = host.register_binding('alone', 'Alone', nil, NATIVE)
    assert(not ok and why == RESERVED and state.assignments.session == session, 'session ' .. session)
end
new_session()
assert(host.register_binding('alone', 'Alone', nil, NATIVE) and state.registry.alone.code == first_action)
assert(state.assignments.session == 32 and state.assignments.actions[first_action].clear)
print('A refused registration counts its session, so the reservations of mods that are gone expire OK')

-- Reported case (MBM v2 plan audit, 2026-10-13): two v1.1 addons both ask for
-- slot 2. v2.2.1 gave the slot to the first caller of each session, so with
-- the load order reversed A moved to an automatic action, B took slot 2's
-- action, and B inherited A's saved keys while A lost them. Keys are saved by
-- the game per native action, so a binding must stay on its action.
local SLOT2 = 12 * 65536
local function code_of(id) return state.registry[id].code end
reset_registry()
remove_assignments()
assert(host.register_binding('legacy.a', 0x3ef7f7ad, 2) and code_of('legacy.a') == SLOT2)
assert(host.register_binding('legacy.b', 0x3ef7f7ad, 2) and state.auto_codes[code_of('legacy.b')])
local a_code, b_code = code_of('legacy.a'), code_of('legacy.b')
new_session()
do
    local file = assert(io.open(assignments, 'rb'))
    local text = file:read('*a')
    file:close()
    assert(text:find('\nslot 2 1 legacy.a\n', 1, true), text)
end
assert(host.register_binding('legacy.b', 0x3ef7f7ad, 2))
assert(host.register_binding('legacy.a', 0x3ef7f7ad, 2))
assert(code_of('legacy.a') == a_code and code_of('legacy.b') == b_code,
       'reversed load order: each v1.1 addon keeps its own native action and keys')
-- The owner absent for a session: the slot stays its own; another caller
-- keeps (or gets) an automatic action and never the owner's keys.
new_session()
assert(host.register_binding('legacy.b', 0x3ef7f7ad, 2) and code_of('legacy.b') == b_code)
assert(host.register_binding('legacy.c', 0x3ef7f7ad, 2) and code_of('legacy.c') ~= SLOT2)
assert(not state.used[SLOT2], 'the absent owner\'s action is not handed out')
-- The owner registers late, after both: it still gets its action.
assert(host.register_binding('legacy.a', 0x3ef7f7ad, 2) and code_of('legacy.a') == SLOT2)
local c_code = code_of('legacy.c')
new_session()
for _, id in ipairs({'legacy.c', 'legacy.a', 'legacy.b'}) do assert(host.register_binding(id, 0x3ef7f7ad, 2)) end
assert(code_of('legacy.a') == SLOT2 and code_of('legacy.b') == b_code and code_of('legacy.c') == c_code)
assert(queued_clears() == 0, 'no keys queued for clearing')
-- The owner once registers without a slot (an automatic reservation of its
-- own), then asks for slot 2 again: its keys are on slot 2's action, so the
-- owner gets that action back.
new_session()
assert(host.register_binding('legacy.a', 0x3ef7f7ad) and state.auto_codes[code_of('legacy.a')])
new_session()
assert(host.register_binding('legacy.a', 0x3ef7f7ad, 2) and code_of('legacy.a') == SLOT2)
print('Reported case: two v1.1 addons on slot 2 keep their own actions in any load order, absent or late OK')

-- A file written by v2.2.1 has no owner line. After the session the audit
-- reproduced (A on slot 2, B moved to 10:0), the reservation shows B was the
-- addon moved: B keeps 10:0 even when it registers first, and A becomes the
-- slot's owner.
reset_registry()
remove_assignments()
do
    local file = assert(io.open(assignments, 'wb'))
    assert(file:write('format 2\nsession 1\nlegacy.b\t10\t0\t1\nend\n'))
    assert(file:close())
end
assert(host.register_binding('legacy.b', 0x3ef7f7ad, 2) and code_of('legacy.b') == 10 * 65536)
assert(host.register_binding('legacy.a', 0x3ef7f7ad, 2) and code_of('legacy.a') == SLOT2)
assert(state.assignments.owners[2].id == 'legacy.a')
print('A v2.2.1 assignments file: the addon it moved keeps its action, the other becomes slot 2\'s owner OK')

-- The owner's reservation ends like an automatic one: after 30 sessions that
-- count without it, a new caller becomes the owner and the old keys are
-- cleared. An addon with an automatic reservation keeps it meanwhile.
new_session()
for session = 3, 32 do
    assert(host.register_binding('legacy.b', 0x3ef7f7ad, 2) and code_of('legacy.b') == 10 * 65536)
    assert(state.assignments.session == session, 'session ' .. tostring(state.assignments.session))
    new_session()
end
assert(host.register_binding('legacy.d', 0x3ef7f7ad, 2) and code_of('legacy.d') == SLOT2)
assert(state.assignments.actions[SLOT2].clear and state.assignments.owners[2].id == 'legacy.d',
       'expired owner: the slot goes to the new caller, its old keys to be cleared')
assert(host.register_binding('legacy.a', 0x3ef7f7ad, 2) and state.auto_codes[code_of('legacy.a')])
print('Slot 2\'s owner expires after 30 sessions without it; the next caller gets the slot, cleared OK')
reset_registry()
remove_assignments()

-- Version 2 categories: explicit, derived from the addon entry, validated.
new_session()
assert(host.register_binding('a', 0x3ef7f7ad, 1, {category = '  Ship Station Hotkeys '}))
assert(state.registry.a.category == 'SHIP STATION HOTKEYS')
local entry = assert(loadstring(
    'local menu = ... local ok = menu.register_binding("b", 0x3ef7f7ad, 2) return ok',
    '@mods/example/toggle_hud'))
assert(entry(host))
assert(state.registry.b.category == 'TOGGLE HUD')
local wrapped = assert(loadstring(
    'local menu = ... local ok, result = pcall(menu.register_binding, "c", 0x3ef7f7ad, 3) return ok, result',
    '@mods/example/pad_tools'))
local called, registered = wrapped(host)
assert(called and registered and state.registry.c.category == 'PAD TOOLS')
assert(not host.register_binding('d', 0x3ef7f7ad, 4, {category = ''}))
assert(not host.register_binding('d', 0x3ef7f7ad, 4, {category = 12}))
assert(not host.register_binding('d', 0x3ef7f7ad, 4, {category = string.rep('x', 65)}))
assert(not host.register_binding('d', 0x3ef7f7ad, 4, 'category'))
assert(host.register_binding('d', 'Free Text', 4))
assert(state.registry.d.text == 'FREE TEXT')
print('Binding categories and string labels OK')
remove_assignments()

-- An unsupported game build: the test process's own executable stands in for
-- game.dll, so the real build check hashes both module files and finds no
-- match. The first frame stops the update for the session, the family's
-- refusal: BingusRuntime.statuses shows "stopped: unsupported game build", the
-- log has that stop line and a note that nothing in the game was changed, and
-- no step runs afterwards (no read, no log line per frame). Not one read is
-- made, so nothing is written either: the fixed slots' keyboard defaults are
-- added only after the build check passes. The bindings stay inert. In a plain test
-- process, without game.dll, the reason is "game modules unavailable".
do
    local function set_upvalue(fn, wanted, value)
        for index = 1, 60 do
            local name = debug.getupvalue(fn, index)
            if name == wanted then debug.setupvalue(fn, index, value); return end
            if name == nil then break end
        end
        error('missing upvalue ' .. wanted)
    end
    local lines = {}
    local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    local function fresh()
        _G.ModBindingsMenu, _G.BingusRuntime = nil, nil
        _G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
        _G.update = function() end
        dofile(source)
        return ModBindingsMenu, update, BingusRuntime.statuses.ModBindingsMenu
    end
    local inert, wrapper, status = fresh()
    local real_step = upvalue(wrapper, 'step')
    local initialize = upvalue(real_step, 'initialize')
    local memory, read = upvalue(initialize, 'memory'), upvalue(initialize, 'read')
    -- The step's runs and the menu's reads, counted.
    local steps, reads = 0, 0
    set_upvalue(wrapper, 'step', function(...)
        steps = steps + 1
        return real_step(...)
    end)
    local kernel32 = upvalue(read, 'kernel32')
    set_upvalue(read, 'kernel32', setmetatable({
        MBM_ReadProcessMemory = function(...) reads = reads + 1; return kernel32.MBM_ReadProcessMemory(...) end,
        MBM_read_at = function(...) reads = reads + 1; return kernel32.MBM_read_at(...) end,
    }, {__index = kernel32}))
    local module = memory.module
    memory.module = function() return module(nil) end
    local before = #lines
    wrapper(0.016)
    memory.module = module
    assert(status.state == 'stopped: unsupported game build', status.state)
    assert(#lines == before + 2 and lines[before + 1] == 'ModBindingsMenu stopped: unsupported game build\n',
           lines[before + 1])
    local inactive = lines[before + 2]
    for _, words in ipairs({'inactive on this game build', 'changes nothing in the game', 'no keyboard defaults added',
                            'Update it'}) do
        assert(inactive:find(words, 1, true), inactive)
    end
    for _ = 1, 30 do wrapper(0.016) end
    assert(steps == 1 and reads == 0 and #lines == before + 2, 'no step, read or log line after the refusal')
    assert(inert.register_binding('inert', 'Inert', 1) and inert.is_down('inert') == nil and not inert.ready())
    local logged = #lines
    initialize()
    assert(#lines == logged, 'the build check and its note run once')
    set_upvalue(read, 'kernel32', kernel32)
    local _, plain, plain_status = fresh()
    before = #lines
    plain(0.016)
    assert(plain_status.state == 'stopped: game modules unavailable' and #lines == before + 2
           and lines[before + 1] == 'ModBindingsMenu stopped: game modules unavailable\n', plain_status.state)
    _G.CowboyBingusModLoader = {log_directory = directory}
end
print('An unsupported game build stops the update, the guard\'s refusal: one stop line and a note that nothing '
      .. 'was changed, no read or write at all, no step or log line afterwards, inert bindings OK')
remove_assignments()
