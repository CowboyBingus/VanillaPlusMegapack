-- Ship Station Hotkeys reads its bindings with Mod Bindings Menu's poll (one
-- call per focused frame) where the menu offers it, else with is_down (one call
-- per registered shortcut). Both must behave the same. Two instances run the
-- same generated frames: A with a Mod Bindings Menu that offers only is_down
-- (v2.1 and older), B with one that offers poll too, both answering from the
-- same binding states. Every frame both make the same engine, window, key,
-- registration, memory and native calls in the same order, write the same log
-- lines, keep the same shortcut states and leave the same presenter state;
-- only their Mod Bindings Menu reads differ. A poll that raises or refuses is
-- logged once and B asks is_down from then on, still behaving as A.
-- Two more instances run the same frames with bindings that always answer
-- (true or false) and with the game's mission record and the bindings' state
-- bytes: C with the idle gate (Mod Bindings Menu's v2.0-v2.2.1 layout), which
-- asks Mod Bindings Menu only while a binding's action is down, and D with
-- poll on every frame aboard. Both must write the same log lines, keep the same
-- shortcut states, leave the same presenter state and agree on ship and mission.
-- Usage: luajit test_binding_paths.lua [path to src/galactic_menu_hotkey.lua]
local ffi = require('ffi')
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/galactic_menu_hotkey.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local Text = dofile(root .. '/src/bingus_text.lua')
local ENGLISH = dofile(root .. '/locales/en.lua')

local function holder(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 60 do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == wanted then return fn, index, value end
        if type(value) == 'function' then nested[#nested + 1] = value end
    end
    for _, inner in ipairs(nested) do
        local found, index, value = holder(inner, wanted, seen)
        if found then return found, index, value end
    end
    return nil
end
local function upvalue(fn, wanted)
    local found, _, value = holder(fn, wanted)
    assert(found, 'missing upvalue ' .. wanted)
    return value
end

-- The generated world both instances see: the main world and the world list,
-- the window in front, the fixed keys held, and each binding's answer (true,
-- false or nil: no binding) in Mod Bindings Menu.
local SHIP_WORLD, MISSION_WORLD, UI_WORLD, GALAXY = {}, {}, {}, {1}
local GAME_WINDOW, OTHER_WINDOW = 0x1234, 0x5678
local world = {main = MISSION_WORLD, list = {MISSION_WORLD, UI_WORLD}, window = GAME_WINDOW, keys = {}, answers = {}}
local function world_name(w)
    return w == SHIP_WORLD and 'ship' or w == MISSION_WORLD and 'mission' or w == UI_WORLD and 'ui' or tostring(w)
end

-- One instance: its own game memory (the UI state pointer and the presenter
-- manager), its own engine, window and key fakes and its own log. Every call
-- it makes outside Mod Bindings Menu's reads goes into calls, in order.
local PRESENTER_OFFSET = 17032
-- game.dll's globals from the mission record pointer (0x33266a0) to the input
-- owner pointer (0x347cf18), for C and D.
local FIRST_GLOBAL, LAST_GLOBAL = 0x33266a0, 0x347cf18
local function instance(name, globals)
    local side = {name = name, calls = {}, lines = {}, mbm = {is_down = 0, poll = 0}}
    local function record(...) side.calls[#side.calls + 1] = table.concat({...}, ' ') end
    side.record = record
    if globals then
        -- The mission record (flag at +8, type at +0x40) and the input owner (an
        -- action's state byte at +808 + 32 * (97 * group + action)).
        side.globals = ffi.new('uint8_t[?]', LAST_GLOBAL - FIRST_GLOBAL + 8)
        side.module = side.globals - FIRST_GLOBAL
        side.mode = ffi.new('uint8_t[72]')
        side.owner = ffi.new('uint8_t[?]', 808 + 32 * 97 * 13)
        ffi.cast('uint64_t *', side.module + FIRST_GLOBAL)[0] = ffi.cast('uint64_t', side.mode)
        ffi.cast('uint64_t *', side.module + LAST_GLOBAL)[0] = ffi.cast('uint64_t', side.owner)
    else
        side.module = ffi.new('uint8_t[?]', 0x347ce28 + 24)
    end
    side.ui = ffi.new('uint8_t[?]', PRESENTER_OFFSET + 64)
    ffi.cast('uint64_t *', side.module + 0x347ce28)[0] = ffi.cast('uint64_t', side.ui)
    side.current = ffi.cast('uint32_t *', side.ui + PRESENTER_OFFSET + 12)
    side.depth = ffi.cast('uint32_t *', side.ui + PRESENTER_OFFSET + 40)
    side.engine = {
        Application = {
            main_world = function() record('main_world'); return world.main end,
            worlds = function() record('worlds'); return world.list end,
        },
        World = {units_by_resource = function(w)
            record('units_by_resource', world_name(w))
            return w == SHIP_WORLD and GALAXY or {}
        end},
        IdString64 = {from_hex = function(hex) record('from_hex', hex); return 'galaxy table' end},
    }
    _G.GalacticMenuHotkeyInstalled, _G.BingusTranslations, _G.ModBindingsMenu, _G.BingusRuntime = nil, nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.ssh_text = {module = Text, locales = {en = ENGLISH, bundled = {}}}
    _G.ssh_runtime = {core = assert(loadfile(root .. '/src/bingus_runtime.lua')),
                      memory = assert(loadfile(root .. '/src/bingus_memory.lua'))}
    _G.CowboyBingusModLoader = {open_log = function()
        return {write = function(_, text) side.lines[#side.lines + 1] = text end, flush = function() end}
    end}
    _G.update = function() end
    _G.stingray = side.engine
    dofile(source)
    side.update, side.state = update, upvalue(update, 'state')
    side.shortcuts = upvalue(update, 'SHORTCUTS')
    local process_id = upvalue(update, 'process_id')
    -- Windows calls by their private names (GMH_ and the real name).
    local user32_holder, user32_index, real_user32 = holder(update, 'user32')
    local fake_user32 = {
        GMH_GetForegroundWindow = function() record('GetForegroundWindow'); return world.window end,
        GMH_GetWindowThreadProcessId = function(window, process)
            record('GetWindowThreadProcessId', window)
            process[0] = window == GAME_WINDOW and process_id or process_id + 1
            return 1
        end,
        GMH_GetAsyncKeyState = function(key) record('GetAsyncKeyState', key); return world.keys[key] and -32768 or 0 end,
    }
    debug.setupvalue(user32_holder, user32_index, setmetatable(fake_user32, {__index = real_user32}))
    local kernel_holder, kernel_index, real_kernel = holder(update, 'kernel32')
    local base = tonumber(ffi.cast('uint64_t', side.module))
    local ui = tonumber(ffi.cast('uint64_t', side.ui))
    debug.setupvalue(kernel_holder, kernel_index, setmetatable({
        GMH_ReadProcessMemory = function(process, address, buffer, size, received)
            local at = tonumber(ffi.cast('uint64_t', address))
            record('ReadProcessMemory', at >= ui and at < ui + PRESENTER_OFFSET + 64 and 'ui+' .. (at - ui)
                   or 'base+' .. (at - base), size)
            return real_kernel.GMH_ReadProcessMemory(process, address, buffer, size, received)
        end,
    }, {__index = real_kernel}))
    -- Outside the game the native layer is unavailable: the native check, which
    -- would refuse, is marked done, and the presenter entry is a fake that opens
    -- the presenter asked for.
    side.state.initialized = true
    side.state.game_base = base
    side.state.open_presenter = function(manager, kind)
        record('open_presenter', kind)
        side.current[0], side.depth[0] = kind, 1
    end
    return side
end

-- Mod Bindings Menu tables: register_binding refuses an id its first refused[id]
-- tries on that table; is_down and poll answer from world.answers. poll is on
-- B's table only; broken makes it raise, refuse makes it return false.
-- C's and D's tables (bound = true) answer true or false, never nil (no binding
-- unavailable once registered and ready); C's (gate = true) has the layout the
-- idle gate knows: 36 actions and ready, under API version 3 or 4 (version).
local function host(side, with_poll, refused, faults, bound, gate, version)
    local tries = {}
    local menu = {version = version or 3}
    local function answer(id)
        if bound then return world.answers[id] == true end
        return world.answers[id]
    end
    function menu.register_binding(id, _, slot)
        side.record('register_binding', id, tostring(slot))
        tries[id] = (tries[id] or 0) + 1
        if tries[id] <= (refused[id] or 0) then return false, 'slot already in use' end
        return true
    end
    function menu.is_down(id)
        side.mbm.is_down = side.mbm.is_down + 1
        return answer(id)
    end
    if with_poll then
        function menu.poll(ids, out)
            side.mbm.poll = side.mbm.poll + 1
            if faults.broken then error('poll broke', 0) end
            if faults.refuse then return false, 'invalid poll arguments' end
            out.down = out.down or {}
            for index = 1, #ids do out.down[index] = answer(ids[index]) end
            return true
        end
    end
    if gate then
        menu.capacity = 36
        function menu.ready() return true end
    end
    return menu
end

local a, b = instance('A'), instance('B')
-- C reads its bindings through the idle gate, D through poll on every frame
-- aboard; both see the mission record and the bindings' state bytes.
local c, d = instance('C', true), instance('D', true)
local SLOT_ACTIONS = {{12, 1}, {12, 0}, {10, 1}, {10, 4}, {10, 8}, {10, 14}, {10, 9}}
-- The game's state for C and D: the mission flag and type, and each binding's state byte.
local function sync_globals(side)
    local mission = world.main == MISSION_WORLD
    ffi.cast('uint32_t *', side.mode + 8)[0] = mission and 1 or 0
    ffi.cast('uint32_t *', side.mode + 0x40)[0] = mission and 1 or 0
    for _, shortcut in ipairs(side.shortcuts) do
        local action = SLOT_ACTIONS[shortcut.slot]
        side.owner[808 + 32 * (action[1] * 97 + action[2])] = world.answers[shortcut.id] == true and 1 or 0
    end
end
local IDS = {}
for index, shortcut in ipairs(a.shortcuts) do IDS[index] = shortcut.id end
local seed = 20261004
local function random(n)
    seed = seed * 16807 % 2147483647
    return seed % n
end
-- The current Mod Bindings Menu generation: each side's table, or none.
local hosts, faults, generation = nil, {}, 0
local function new_hosts()
    generation, faults = generation + 1, {}
    -- Some ids are refused on their first tries; sometimes every id is, so
    -- nothing is registered until a retry.
    local refused, all = {}, random(4) == 0
    for _, id in ipairs(IDS) do refused[id] = (all or random(4) == 0) and 1 + random(2) or 0 end
    -- C's table is a version 3 table (v2.0-v2.2.1) and a version 4 one (v2.3) in
    -- turn, one per generation; the gate stands in for both.
    hosts = {A = host(a, false, refused, faults), B = host(b, true, refused, faults),
             C = host(c, true, refused, faults, true, true, 3 + generation % 2), D = host(d, true, refused, faults, true, false)}
end
new_hosts()
local present = true

local seen = {polls = 0, polled_nil = 0, acted = 0, fixed_keys = 0, focus_changes = 0, ship_frames = 0,
              poll_failures = 0, raised = 0, refused = 0, generations = 0, unregistered = 0,
              gated_idle = 0, gated_idle_v4 = 0, gated_acted = 0, missions = 0}
-- Each change has a chance per frame; leaving the ship, the game's focus or
-- Mod Bindings Menu is rarer than coming back.
local function chance(per_10000) return random(10000) < per_10000 end
local function generate(frame_no)
    if chance(8) then
        new_hosts()
        seen.generations = seen.generations + 1
    end
    if chance(present and 5 or 200) then present = not present end
    if chance(world.main == SHIP_WORLD and 10 or 100) then
        world.main = world.main == SHIP_WORLD and MISSION_WORLD or SHIP_WORLD
        world.list = {world.main, UI_WORLD}
    end
    if chance(world.window == GAME_WINDOW and 50 or 500) then
        world.window = world.window == GAME_WINDOW and OTHER_WINDOW or GAME_WINDOW
        seen.focus_changes = seen.focus_changes + 1
    end
    if chance(2) then faults.broken = true end
    if chance(2) then faults.refuse = true end
    for index, id in ipairs(IDS) do
        if random(100) < 4 then
            local pick = random(10)
            if pick == 0 then world.answers[id] = nil else world.answers[id] = pick < 6 end
        end
        if random(100) < 4 then world.keys[a.shortcuts[index].key] = random(2) == 0 end
    end
    -- A presenter that opened closes again (one draw for both sides, whose
    -- presenters are checked equal every frame); sometimes another menu is busy.
    if a.current[0] ~= 0 and random(40) == 0 then
        for _, side in ipairs({a, b}) do side.current[0], side.depth[0] = 0, 0 end
    end
    if c.current[0] ~= 0 and random(40) == 0 then
        for _, side in ipairs({c, d}) do side.current[0], side.depth[0] = 0, 0 end
    end
    if frame_no % 997 == 0 then
        for _, side in ipairs({a, b, c, d}) do side.current[0], side.depth[0] = 2, 1 end
    end
end

local POLL_FAILED = 'Mod Bindings Menu poll failed'
local function run(side, dt)
    _G.ModBindingsMenu = present and hosts[side.name] or nil
    _G.stingray = side.engine
    side.update(dt)
end
local function same_list(x, y, what, frame_no)
    assert(#x == #y, string.format('frame %d: %d and %d %s', frame_no, #x, #y, what))
    for index = 1, #x do
        assert(x[index] == y[index], string.format('frame %d, %s %d: %s | %s', frame_no, what, index, x[index], y[index]))
    end
end
-- One side's log lines since before, without its poll failure lines.
local function new_lines(side, before)
    local lines = {}
    for index = before + 1, #side.lines do
        if not side.lines[index]:find(POLL_FAILED, 1, true) then lines[#lines + 1] = side.lines[index] end
    end
    return lines
end
-- C (the idle gate) and D (poll on every frame aboard) on the same frame: the
-- same log lines (poll failures aside: C polls only while a binding is down),
-- shortcut states, presenter state and ship. C asks Mod Bindings Menu nothing
-- on an idle frame aboard while its gate stands in for it.
local function compare_gate(frame_no, dt)
    sync_globals(c)
    sync_globals(d)
    c.calls, d.calls = {}, {}
    local c_before, d_before, c_asked = #c.lines, #d.lines, c.mbm.poll + c.mbm.is_down
    run(c, dt)
    run(d, dt)
    same_list(new_lines(c, c_before), new_lines(d, d_before), 'C and D log lines', frame_no)
    for _, id in ipairs(IDS) do
        assert((c.state.keys_down[id] == true) == (d.state.keys_down[id] == true),
               'frame ' .. frame_no .. ': C and D shortcut state of ' .. id)
    end
    assert(c.current[0] == d.current[0] and c.depth[0] == d.depth[0], 'frame ' .. frame_no .. ': C and D presenter')
    assert((c.state.world == nil) == (d.state.world == nil) and c.state.in_mission == d.state.in_mission,
           'frame ' .. frame_no .. ': C and D ship')
    local asked = c.mbm.poll + c.mbm.is_down > c_asked
    if c.state.world and present and c.state.gate and not asked then
        seen.gated_idle = seen.gated_idle + 1
        if hosts.C.version == 4 then seen.gated_idle_v4 = seen.gated_idle_v4 + 1 end
    end
    for _, call in ipairs(c.calls) do
        if call:find('^open_presenter') then seen.gated_acted = seen.gated_acted + 1 end
    end
    if c.state.in_mission then seen.missions = seen.missions + 1 end
end
local FRAMES = 30000
-- Idle frames the gate answers alone, at least, with each Mod Bindings Menu version.
local GATED_V4_MIN = 300
-- B's log lines without its poll failure lines (one per failing table).
local b_lines = {}
for index = 1, #b.lines do b_lines[index] = b.lines[index] end
for frame_no = 1, FRAMES do
    generate(frame_no)
    local dt = (1 + random(3)) / 120
    a.calls, b.calls = {}, {}
    local polls, a_is_down, b_is_down = b.mbm.poll, a.mbm.is_down, b.mbm.is_down
    local a_before, b_before, failures = #a.lines, #b.lines, seen.poll_failures
    run(a, dt)
    run(b, dt)
    same_list(a.calls, b.calls, 'calls', frame_no)
    for index = b_before + 1, #b.lines do
        if b.lines[index]:find(POLL_FAILED, 1, true) then
            seen.poll_failures = seen.poll_failures + 1
            if b.lines[index]:find('(poll broke)', 1, true) then seen.raised = seen.raised + 1 end
            if b.lines[index]:find('(invalid poll arguments)', 1, true) then seen.refused = seen.refused + 1 end
        else
            b_lines[#b_lines + 1] = b.lines[index]
        end
    end
    assert(seen.poll_failures - failures <= 1, 'frame ' .. frame_no .. ': one failure line')
    assert(#a.lines == #b_lines, 'frame ' .. frame_no .. ': the same number of log lines')
    for index = a_before + 1, #a.lines do
        assert(a.lines[index] == b_lines[index], string.format('frame %d, log line %d: %s | %s', frame_no, index,
               a.lines[index], b_lines[index]))
    end
    for index, id in ipairs(IDS) do
        assert(a.state.now[index] == b.state.now[index] and a.state.keys_down[id] == b.state.keys_down[id],
               'frame ' .. frame_no .. ': shortcut state of ' .. id)
    end
    assert(a.current[0] == b.current[0] and a.depth[0] == b.depth[0], 'frame ' .. frame_no .. ': presenter')
    assert(a.state.focused == b.state.focused and (a.state.world == nil) == (b.state.world == nil))
    -- B polls at most once per frame and then asks no is_down, unless that poll
    -- failed: then it was logged and is_down answers, from this frame on.
    local b_polled, failed = b.mbm.poll - polls, seen.poll_failures > failures
    assert(b_polled <= 1 and (b_polled == 0 or b.mbm.is_down == b_is_down or failed), 'frame ' .. frame_no ..
           ': one poll')
    assert(not failed or b_polled == 1 and not b.state.binding_poll, 'frame ' .. frame_no .. ': a failed poll')
    if failed then faults.logged = true end
    -- B polls only while a shortcut is registered, and every table that offers
    -- poll is polled until its poll fails.
    assert(b_polled == 0 or next(b.state.binding_slots), 'frame ' .. frame_no .. ': nothing registered to poll')
    assert(b.state.binding_host ~= hosts.B or faults.logged or b.state.binding_poll,
           'frame ' .. frame_no .. ': a table that offers poll is polled')
    if b_polled == 1 and b.state.binding_poll then
        seen.polls = seen.polls + 1
        for index, id in ipairs(IDS) do
            if world.answers[id] == nil and b.state.binding_slots[id] then seen.polled_nil = seen.polled_nil + 1 end
        end
    end
    if a.mbm.is_down == a_is_down and a.state.focused and a.state.world then
        seen.fixed_keys = seen.fixed_keys + 1
        if present and not next(b.state.binding_slots) then seen.unregistered = seen.unregistered + 1 end
    end
    for _, call in ipairs(a.calls) do
        if call:find('^open_presenter') then seen.acted = seen.acted + 1 end
    end
    compare_gate(frame_no, dt)
    if a.state.world then seen.ship_frames = seen.ship_frames + 1 end
end
for index = 1, #a.lines do assert(not a.lines[index]:find('Update error', 1, true), a.lines[index]) end
assert(seen.polls >= 10000 and seen.polled_nil >= 5000 and seen.acted >= 200 and seen.fixed_keys >= 300
       and seen.focus_changes >= 100 and seen.raised >= 2 and seen.refused >= 2 and seen.generations >= 10
       and seen.ship_frames >= 10000 and seen.poll_failures == seen.raised + seen.refused and seen.unregistered >= 50,
       string.format('coverage: %d polls, %d nil answers polled, %d presenters opened, %d frames on fixed keys (%d with '
       .. 'nothing registered), %d focus changes, %d polls raised and %d refused, %d tables, %d ship frames', seen.polls,
       seen.polled_nil, seen.acted, seen.fixed_keys, seen.unregistered, seen.focus_changes, seen.raised, seen.refused,
       seen.generations, seen.ship_frames))
print(string.format('poll and is_down paths over %d generated frames: the same calls, log lines, shortcut states and '
      .. 'presenter state on every frame; %d frames answered by one poll (%d nil answers on fixed keys), %d presenters '
      .. 'opened, %d frames on fixed keys only (%d with Mod Bindings Menu but nothing registered), %d focus changes, %d '
      .. 'Mod Bindings Menu tables, %d polls that raised and %d that refused, each logged once OK', FRAMES, seen.polls,
      seen.polled_nil, seen.acted, seen.fixed_keys, seen.unregistered, seen.focus_changes, seen.generations, seen.raised,
      seen.refused))
for index = 1, #c.lines do assert(not c.lines[index]:find('Update error', 1, true), c.lines[index]) end
assert(seen.gated_idle >= 1000 and seen.gated_idle_v4 >= GATED_V4_MIN and seen.gated_idle - seen.gated_idle_v4 >= GATED_V4_MIN
       and seen.gated_acted >= 200 and seen.missions >= 1000,
       string.format('gate coverage: %d idle frames (%d with version 4), %d presenters opened, %d mission frames',
                     seen.gated_idle, seen.gated_idle_v4, seen.gated_acted, seen.missions))
print(string.format('idle gate and poll on every frame over the same %d frames: the same log lines, shortcut states, '
      .. 'presenter state and ship on every frame; %d idle frames aboard answered by the gate alone (%d with Mod '
      .. 'Bindings Menu version 3, %d with version 4), %d presenters opened, %d frames in a mission OK', FRAMES,
      seen.gated_idle, seen.gated_idle - seen.gated_idle_v4, seen.gated_idle_v4, seen.gated_acted, seen.missions))
