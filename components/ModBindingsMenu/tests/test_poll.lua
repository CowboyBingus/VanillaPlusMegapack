-- ModBindingsMenu.poll(ids, out), the batch edge API, against simulated game
-- memory: its contract and edges (across a config re-parse, a binding page,
-- unavailable bindings and frames not polled); a differential against is_down
-- over generated frames, with two instances on two identical simulated games
-- (the same answers, sweeps, binding maps, log lines and assignments files on
-- every frame); and no allocation per call, interpreted and compiled.
-- Usage: luajit test_poll.lua [path to src/mod_bindings_menu.lua]
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local ffi = require('ffi')
ffi.cdef [[
int mbm_test_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");
int mbm_test_memcmp(const void *a, const void *b, size_t size) __asm__("memcmp");
]]
local kernel32, crt = ffi.load('kernel32'), ffi.load('msvcrt')
local TEMP = assert(os.getenv('TEMP') or os.getenv('TMP'))

local function put32(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
local function address_of(cdata) return tonumber(ffi.cast('uint64_t', cdata)) end
-- An upvalue of fn, or (holder) the function holding it among those fn reaches.
local function holder(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 80 do
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
-- Replaces the upvalue wanted of the function that holds it (shared by every
-- function closing over the same local); returns the old value.
local function replace(fn, wanted, value)
    local found, index, old = holder(fn, wanted)
    assert(found, 'missing upvalue ' .. wanted)
    debug.setupvalue(found, index, value)
    return old
end

-- 20-byte mappings: flags (device, Button, any slot, trigger), key, two unset
-- bytes, the trigger again, combine, threshold.
local PRESS, HOLD, REPEAT = 0, 2, 8
local KEYBOARD, MOUSE, XBOX, DUALSHOCK = 3, 2, 5, 6
local function mapping(device, key, trigger)
    trigger = trigger or PRESS
    local cell = ffi.new('uint8_t[20]')
    ffi.cast('uint32_t *', cell)[0] = device + 0x40 + 0xff00 + trigger * 0x10000 + key * 0x100000
    ffi.cast('uint16_t *', cell + 4)[0] = key
    ffi.cast('uint32_t *', cell + 8)[0] = trigger
    return ffi.string(cell, 20)
end
local function code_of(group, action) return group * 65536 + action end
-- Shipped defaults (as input.config's) of the actions the bindings below use:
-- slot 1 keeps its own Tab, slot 3 its own F1 (Mod Bindings Menu's keyboard
-- defaults); every other mapping is an inherited developer default.
local DEFAULTS = {
    [code_of(12, 1)] = {mapping(DUALSHOCK, 9), mapping(XBOX, 9), mapping(KEYBOARD, 76), mapping(MOUSE, 1)},
    [code_of(10, 1)] = {mapping(XBOX, 4), mapping(KEYBOARD, 59)},
    [code_of(10, 4)] = {mapping(DUALSHOCK, 5, HOLD)},
    [code_of(10, 0)] = {mapping(KEYBOARD, 81, HOLD), mapping(XBOX, 3, HOLD)},
    [code_of(10, 2)] = {mapping(XBOX, 4, REPEAT), mapping(KEYBOARD, 80, REPEAT)},
    [code_of(10, 3)] = {mapping(KEYBOARD, 79)},
    [code_of(10, 5)] = {mapping(MOUSE, 2)},
}

-- A simulated game: the image (UI pointers, the input owner pointer), the input
-- owner with its action states and both binding maps (256 records of {code,
-- count, 16 x 20-byte mappings}), the UI's screen stack and the menu system.
-- Every game puts each dormant action's record at the same bucket.
local Text = dofile(root .. '/src/bingus_text.lua')
_G.mbm_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})
local RECORD = 328
local OWNER_SLOT, UI_SLOT, MENU_SLOT = 0x347cf18, 0x347ce28, 0x347ce38
local position, dormant = {}, nil
local function new_game()
    local game = {image = ffi.new('uint8_t[?]', 0x3480000), owner = ffi.new('uint8_t[?]', 687000),
                  live = ffi.new('uint8_t[?]', 256 * RECORD), shipped = ffi.new('uint8_t[?]', 256 * RECORD),
                  ui = ffi.new('uint8_t[?]', 0x429c + 24), menu = ffi.new('uint8_t[?]', 216),
                  screen = ffi.new('uint8_t[?]', 60000)}
    game.base = address_of(game.image)
    put64(game.base + OWNER_SLOT, address_of(game.owner))
    put64(address_of(game.owner) + 686800, address_of(game.live))
    put32(address_of(game.owner) + 686808, 256)
    put64(address_of(game.owner) + 686968, address_of(game.shipped))
    put32(address_of(game.owner) + 686976, 256)
    put64(game.base + UI_SLOT, address_of(game.ui))
    put64(game.base + MENU_SLOT, address_of(game.menu))
    put64(address_of(game.menu) + 208, address_of(game.screen))
    put32(address_of(game.ui) + 0x429c + 20, 1)
    put32(address_of(game.ui) + 0x429c, 1)
    return game
end
local function record_at(game, map, code) return address_of(game[map]) + position[code] * RECORD end
local function set_list(game, map, code, list)
    local address = record_at(game, map, code)
    put32(address + 4, #list)
    ffi.fill(ffi.cast('uint8_t *', address + 8), 320)
    for index, blob in ipairs(list) do ffi.copy(ffi.cast('uint8_t *', address + 8 + (index - 1) * 20), blob, 20) end
end
local function list_count(game, code) return tonumber(ffi.cast('uint32_t *', record_at(game, 'live', code) + 4)[0]) end
-- Every dormant action's record in both maps, holding its shipped defaults.
local function install(game)
    for _, entry in ipairs(dormant) do
        local code = code_of(entry[1], entry[2])
        for _, map in ipairs({'live', 'shipped'}) do
            put32(record_at(game, map, code), code)
            set_list(game, map, code, DEFAULTS[code] or {})
        end
    end
end
local function state_byte(code) return 808 + 32 * (97 * math.floor(code / 65536) + code % 65536) end
local function hold(game, code, down) game.owner[state_byte(code)] = down and 1 or 0 end
local function page(game, open) put32(address_of(game.ui) + 0x429c, open and 26 or 1) end
local function owner_present(game, present)
    put64(game.base + OWNER_SLOT, present and address_of(game.owner) or 0)
end

-- A fresh Mod Bindings Menu on a simulated game, with its own log and its own
-- folder for the assignments file. Call use(instance) before anything that may
-- load or save that file: the file's folder comes from the loader global.
local instances = 0
local function use(instance) _G.CowboyBingusModLoader = instance.loader end
local function instance(game)
    instances = instances + 1
    local directory = TEMP .. '/mbm-test-poll-' .. instances
    kernel32.mbm_test_CreateDirectoryA(directory, nil)
    for _, suffix in ipairs({'', '.bak', '.tmp'}) do os.remove(directory .. '/ModBindingsMenu.assignments' .. suffix) end
    local lines = {}
    local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    local new = {game = game, lines = lines, directory = directory,
                 loader = {log_directory = directory, open_log = function() return log end}}
    use(new)
    _G.ModBindingsMenu, _G.BingusTranslations = nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    _G.update, _G.BingusRuntime = function() end, nil
    dofile(source)
    new.menu, new.update = ModBindingsMenu, update
    new.st = upvalue(new.menu.register_binding, 'state')
    new.st.initialized, new.st.base = true, game.base
    new.st.build_rows, new.st.set_tab_labels, new.st.reset_list = function() end, function() end, function() end
    dormant = dormant or upvalue(upvalue(new.update, 'step'), 'DORMANT_ACTIONS')
    return new
end
local function frame(instance, dt)
    use(instance)
    instance.update(dt)
end
-- Bucket positions: each dormant action at its own scattered bucket.
local function place()
    local seed, used = 7, {}
    for _, entry in ipairs(dormant) do
        repeat seed = (seed * 37 + 11) % 256 until not used[seed]
        used[seed], position[code_of(entry[1], entry[2])] = true, seed
    end
end

-- 1. The contract.
local game = new_game()
local one = instance(game)
place()
install(game)
local menu, st = one.menu, one.st
assert(type(menu.poll) == 'function' and type(menu.is_down) == 'function', 'feature test: the field is there')
assert(menu.version == 3 and menu.api == 1, 'poll is a field: no version change')
local MAP, ARMORY, AUTO1, AUTO2 = code_of(12, 1), code_of(10, 1), code_of(10, 0), code_of(10, 2)
assert(menu.register_binding('map', 0xb46c8096, 1) and menu.register_binding('armory', 0x19e97f02, 3))
assert(menu.register_binding('auto.1', 'Auto 1') and menu.register_binding('auto.2', 'Auto 2'))
assert(st.registry['auto.1'].code == AUTO1 and st.registry['auto.2'].code == AUTO2)
frame(one, 2) -- the first sweep clears the inherited developer defaults
assert(list_count(game, MAP) == 1 and list_count(game, ARMORY) == 1 and list_count(game, AUTO1) == 0)

-- Arguments: ids and out must be tables, and out's arrays tables when present;
-- a refusal writes nothing. The arrays are created at the first poll.
local INVALID = 'invalid poll arguments'
for _, case in ipairs({{nil, {}}, {'map', {}}, {{'map'}, nil}, {{'map'}, 'out'}}) do
    local ok, why = menu.poll(case[1], case[2])
    assert(ok == false and why == INVALID)
end
local refused = {down = {}, pressed = {}, released = {}, last = 5}
assert(select(2, menu.poll({'map'}, refused)) == INVALID and refused.down[1] == nil and refused.last == 5)
local partial = {pressed = 'no'}
assert(not menu.poll({'map'}, partial) and partial.down == nil, 'nothing is created when a field is refused')
local out = {}
assert(menu.poll({}, out) == true)
for _, field in ipairs({'down', 'pressed', 'released', 'last'}) do assert(type(out[field]) == 'table', field) end
print('Arguments: tables only, a refusal writes nothing, the arrays are created at the first poll OK')

-- down is what is_down answers: true or false, nil without a binding ('missing'
-- is not registered); a binding first seen down is pressed.
local ids = {'map', 'missing', 'armory', 'auto.1', 'auto.2'}
local function check(expected)
    assert(menu.poll(ids, out) == true)
    for index = 1, #ids do
        local want = expected[index]
        local got = {out.down[index], out.pressed[index], out.released[index], out.last[index]}
        for field = 1, 4 do
            assert(got[field] == want[field], string.format('position %d field %d: %s, expected %s', index, field,
                   tostring(got[field]), tostring(want[field])))
        end
    end
end
local T, F = true, false
hold(game, MAP, true)
hold(game, AUTO1, true)
-- {down, pressed, released, last} per position.
check({{T, T, F, T}, {nil, F, F, F}, {F, F, F, F}, {T, T, F, T}, {F, F, F, F}})
for index, id in ipairs(ids) do assert(menu.is_down(id) == out.down[index], id) end
check({{T, F, F, T}, {nil, F, F, F}, {F, F, F, F}, {T, F, F, T}, {F, F, F, F}})
hold(game, MAP, false)
hold(game, ARMORY, true)
check({{F, F, T, F}, {nil, F, F, F}, {T, T, F, T}, {T, F, F, T}, {F, F, F, F}})
-- Native input unavailable (the input owner is gone, or not ready yet): every
-- binding is nil, and one that was down reports released.
owner_present(game, false)
check({{nil, F, F, F}, {nil, F, F, F}, {nil, F, T, F}, {nil, F, T, F}, {nil, F, F, F}})
owner_present(game, true)
check({{F, F, F, F}, {nil, F, F, F}, {T, T, F, T}, {T, T, F, T}, {F, F, F, F}})
st.build_rows = nil
check({{nil, F, F, F}, {nil, F, F, F}, {nil, F, T, F}, {nil, F, T, F}, {nil, F, F, F}})
st.build_rows = function() end
check({{F, F, F, F}, {nil, F, F, F}, {T, T, F, T}, {T, T, F, T}, {F, F, F, F}})
print('down equals is_down (nil without a binding or native input), edges against the previous poll OK')

-- A config re-parse restores the map's shipped defaults outside the binding
-- pages. Its count changed, so the poll sweeps first and reports the map up for
-- this frame, as is_down would; no state of this frame is trusted, so no
-- binding reports an edge (auto.2, pressed on this frame, reports it on the
-- next) and last keeps the state from before: the map, held throughout, never
-- reports released or pressed.
hold(game, MAP, true)
check({{T, T, F, T}, {nil, F, F, F}, {T, F, F, T}, {T, F, F, T}, {F, F, F, F}})
set_list(game, 'live', MAP, DEFAULTS[MAP])
hold(game, AUTO2, true)
hold(game, ARMORY, false)
check({{F, F, F, T}, {nil, F, F, F}, {F, F, F, T}, {T, F, F, T}, {T, F, F, F}})
assert(list_count(game, MAP) == 1, 'the restored developer defaults are gone')
check({{T, F, F, T}, {nil, F, F, F}, {F, F, T, F}, {T, F, F, T}, {T, T, F, T}})
-- On a binding page a changed list is the player's choice: the state is read
-- and edges are reported. After the page closes, the first poll sweeps (the
-- player's list stays) and trusts nothing again.
page(game, true)
set_list(game, 'live', AUTO1, {mapping(KEYBOARD, 44)})
hold(game, AUTO1, false)
check({{T, F, F, T}, {nil, F, F, F}, {F, F, F, F}, {F, F, T, F}, {T, F, F, T}})
page(game, false)
hold(game, AUTO1, true)
check({{T, F, F, T}, {nil, F, F, F}, {F, F, F, F}, {F, F, F, F}, {T, F, F, T}})
assert(list_count(game, AUTO1) == 1, 'the player\'s list stays')
check({{T, F, F, T}, {nil, F, F, F}, {F, F, F, F}, {T, T, F, T}, {T, F, F, T}})
print('A re-parse: down as is_down, no edges and last kept for that frame; a binding page: edges as usual OK')

-- Frames without a poll (the game out of focus, say) are not seen: edges are
-- against the previous poll with this table. The map released and pressed
-- again in between reports nothing; auto.2 released in between reports
-- released. Setting last[i] to false makes a binding still down report pressed.
for _ = 1, 3 do frame(one, 0.016) end
hold(game, MAP, false)
frame(one, 0.016)
hold(game, MAP, true)
hold(game, AUTO2, false)
frame(one, 0.016)
check({{T, F, F, T}, {nil, F, F, F}, {F, F, F, F}, {T, F, F, T}, {F, F, T, F}})
out.last[1] = false
check({{T, T, F, T}, {nil, F, F, F}, {F, F, F, F}, {T, F, F, T}, {F, F, F, F}})
-- Positions after #ids are left alone; a repeated id answers at each position.
-- Edges are kept per position: position 1 held the map (down) until now.
local function positions(from, to)
    local values = {}
    for index = from, to do
        for _, field in ipairs({'down', 'pressed', 'released', 'last'}) do
            values[#values + 1] = tostring(out[field][index])
        end
    end
    return table.concat(values, ' ')
end
for index = 3, 6 do
    for _, field in ipairs({'down', 'pressed', 'released', 'last'}) do out[field][index] = 'kept' end
end
local after_ids = positions(3, 6)
ids = {'auto.1', 'auto.1'}
hold(game, AUTO1, false)
check({{F, F, T, F}, {F, F, F, F}})
assert(positions(3, 6) == after_ids, 'positions after #ids untouched')
-- An unreadable stretch: each state is read on its own, the same answers.
ids = {'map', 'armory', 'auto.1'}
hold(game, ARMORY, true)
local poll_states = upvalue(menu.poll, 'read_states')
local real_read_into = replace(poll_states, 'read_into', function() return false end)
check({{T, T, F, T}, {T, T, F, T}, {F, F, F, F}})
-- The stretch covers the polled actions only, from the lowest to the highest:
-- auto.1 (10:0) to the map (12:1), then armory (10:1) alone.
local stretches = {}
replace(poll_states, 'read_into', function(address, buffer, size)
    stretches[#stretches + 1] = {address - address_of(game.owner), size}
    return real_read_into(address, buffer, size)
end)
check({{T, F, F, T}, {T, F, F, T}, {F, F, F, F}})
ids = {'armory'}
check({{T, F, F, T}})
replace(poll_states, 'read_into', real_read_into)
assert(#stretches == 2 and stretches[1][1] == state_byte(AUTO1) and stretches[1][2] == state_byte(MAP) -
       state_byte(AUTO1) + 1 and stretches[2][1] == state_byte(ARMORY) and stretches[2][2] == 1,
       'the stretches read')
print('Frames without a poll, re-arming with last, positions after #ids, repeated ids, an unreadable stretch, the '
      .. 'stretch read OK')

-- 2. Differential: is_down for each id in order (instance A) and one poll (B),
-- on two identical simulated games, over generated frames: native input
-- states, config re-parses, binding pages with the player's changes, the input
-- owner gone, binding records moved by a map rebuild, a late registration,
-- unreadable stretches (B), sweeps every 2 seconds, and the menu's update
-- before or after the caller. Every frame: the same answers and sweeps, the
-- same binding maps, swept counts and log lines; B's edges as the README
-- defines them. Last, the same assignments files.
do
    local game_a, game_b = new_game(), new_game()
    install(game_a)
    install(game_b)
    local a, b = instance(game_a), instance(game_b)
    local both = {a, b}
    local function each(fn) for _, side in ipairs(both) do fn(side) end end
    local REGISTERED = {{'map', 0xb46c8096, 1}, {'armory', 0x19e97f02, 3}, {'control', 'Control', 4},
                        {'auto.1', 'Auto 1'}, {'auto.2', 'Auto 2'}, {'auto.3', 'Auto 3'}}
    each(function(side)
        use(side)
        for _, row in ipairs(REGISTERED) do assert(side.menu.register_binding(row[1], row[2], row[3])) end
    end)
    local IDS = {'map', 'armory', 'missing', 'control', 'auto.1', 'armory', 'auto.2', 'late', 'auto.3'}
    local codes = {}
    for _, row in ipairs(REGISTERED) do codes[#codes + 1] = a.st.registry[row[1]].code end
    -- Sweeps during the caller's calls, counted on both sides.
    local sweeps = {a = 0, b = 0}
    local real_a = upvalue(a.menu.is_down, 'sweep_bindings')
    replace(a.menu.is_down, 'sweep_bindings', function(...)
        sweeps.a = sweeps.a + 1
        return real_a(...)
    end)
    local b_header = upvalue(upvalue(b.menu.poll, 'headers'), 'header')
    local real_b = upvalue(b_header, 'sweep_bindings')
    replace(b_header, 'sweep_bindings', function(...)
        sweeps.b = sweeps.b + 1
        return real_b(...)
    end)
    -- Unreadable stretches on B: the next stretch read fails.
    local b_states = upvalue(b.menu.poll, 'read_states')
    local b_read_into, fail_next, failed = upvalue(b_states, 'read_into'), false, 0
    replace(b_states, 'read_into', function(...)
        if fail_next then
            fail_next, failed = false, failed + 1
            return false
        end
        return b_read_into(...)
    end)

    local seed = 20261004
    local function random(n)
        seed = seed * 16807 % 2147483647
        return seed % n
    end
    local free = {}
    for bucket = 0, 255 do free[bucket] = true end
    for _, at in pairs(position) do free[at] = false end
    local out_b, last = {}, {}
    local seen = {untrusted = 0, pressed = 0, released = 0, unavailable = 0, page_reads = 0, moved = 0, polls = 0}
    local page_frames, owner_frames, player_changed = 0, 0, false
    local function games(fn) fn(game_a) fn(game_b) end
    local function generate(frame_no)
        local roll = random(1000)
        if frame_no == 3000 then
            each(function(side) use(side) assert(side.menu.register_binding('late', 'Late')) end)
            codes[#codes + 1] = a.st.registry.late.code
        end
        if page_frames == 0 and owner_frames == 0 then
            if roll < 12 then -- a config re-parse restores some shipped lists
                for _, code in ipairs(codes) do
                    if random(2) == 0 then games(function(g) set_list(g, 'live', code, DEFAULTS[code]) end) end
                end
            elseif roll < 17 then
                page_frames, player_changed = 2 + random(8), false
                games(function(g) page(g, true) end)
            elseif roll < 21 then
                owner_frames = 1 + random(3)
                games(function(g) owner_present(g, false) end)
            elseif roll < 24 then -- a map rebuild moves one record, sometimes with the owner gone
                local code, target = codes[1 + random(#codes)], random(256)
                while not free[target] do target = (target + 1) % 256 end
                games(function(g)
                    local from, to = record_at(g, 'live', code), address_of(g.live) + target * RECORD
                    ffi.copy(ffi.cast('uint8_t *', to), ffi.cast('uint8_t *', from), RECORD)
                    ffi.fill(ffi.cast('uint8_t *', from), RECORD)
                end)
                free[position[code]], free[target], position[code] = true, false, target
                seen.moved = seen.moved + 1
                if random(3) == 0 then
                    owner_frames = 1 + random(3)
                    games(function(g) owner_present(g, false) end)
                end
            end
        elseif page_frames > 0 then
            page_frames = page_frames - 1
            if random(3) == 0 then -- the player rebinds on the page
                local code, key = codes[1 + random(#codes)], 30 + random(40)
                local list = ({{}, {mapping(KEYBOARD, key)}, {mapping(KEYBOARD, key), mapping(MOUSE, 1)}})[1 + random(3)]
                games(function(g) set_list(g, 'live', code, list) end)
                player_changed = true
            end
            if page_frames == 0 then games(function(g) page(g, false) end) end
        else
            owner_frames = owner_frames - 1
            if owner_frames == 0 then games(function(g) owner_present(g, true) end) end
        end
        if roll >= 990 then fail_next = true end
        -- A state byte is any value while the action is active.
        for _, code in ipairs(codes) do
            if random(100) < 15 then
                local value = game_a.owner[state_byte(code)] == 0 and 1 + random(255) or 0
                games(function(g) g.owner[state_byte(code)] = value end)
            end
        end
    end
    local function same_maps()
        return crt.mbm_test_memcmp(game_a.live, game_b.live, 256 * RECORD) == 0
    end
    local function same_counts()
        for code, count in pairs(a.st.swept_counts) do
            if b.st.swept_counts[code] ~= count then return false end
        end
        for code, count in pairs(b.st.swept_counts) do
            if a.st.swept_counts[code] ~= count then return false end
        end
        return true
    end
    local answers = {}
    local function caller(frame_no)
        use(a)
        local before_a = sweeps.a
        for index, id in ipairs(IDS) do answers[index] = a.menu.is_down(id) end
        use(b)
        local before_b = sweeps.b
        assert(b.menu.poll(IDS, out_b) == true)
        seen.polls = seen.polls + 1
        local swept = sweeps.b - before_b
        assert(sweeps.a - before_a == swept, 'frame ' .. frame_no .. ': the same sweeps')
        if page_frames > 0 and player_changed then seen.page_reads = seen.page_reads + 1 end
        if swept > 0 then seen.untrusted = seen.untrusted + 1 end
        for index = 1, #IDS do
            local down = out_b.down[index]
            assert(down == answers[index], string.format('frame %d, %s: poll %s, is_down %s', frame_no, IDS[index],
                   tostring(down), tostring(answers[index])))
            if down == nil and IDS[index] ~= 'missing' and (IDS[index] ~= 'late' or frame_no > 3000) then
                seen.unavailable = seen.unavailable + 1
            end
            local now, before = down == true, last[index] == true
            local pressed, released = false, false
            if swept == 0 then pressed, released, last[index] = now and not before, before and not now, now end
            assert(out_b.pressed[index] == pressed and out_b.released[index] == released
                   and out_b.last[index] == (last[index] == true), 'frame ' .. frame_no .. ': edges of ' .. IDS[index])
            seen.pressed = seen.pressed + (pressed and 1 or 0)
            seen.released = seen.released + (released and 1 or 0)
        end
    end
    local FRAMES = 20000
    for frame_no = 1, FRAMES do
        generate(frame_no)
        local dt = random(100) < 2 and 2 or 0.016
        if random(2) == 0 then
            caller(frame_no)
            each(function(side) frame(side, dt) end)
        else
            each(function(side) frame(side, dt) end)
            caller(frame_no)
        end
        assert(same_maps(), 'frame ' .. frame_no .. ': the same binding maps')
        assert(same_counts(), 'frame ' .. frame_no .. ': the same swept counts')
        assert(#a.lines == #b.lines and a.lines[#a.lines] == b.lines[#b.lines], 'frame ' .. frame_no .. ': log lines')
    end
    for index = 1, #a.lines do assert(a.lines[index] == b.lines[index], a.lines[index]) end
    each(function(side) frame(side, 0) end)
    local function saved(side)
        local file = assert(io.open(side.directory .. '/ModBindingsMenu.assignments', 'rb'))
        local text = file:read('*a')
        file:close()
        return text
    end
    assert(saved(a) == saved(b) and saved(a):find('\nlate\t10\t5\t', 1, true), 'the same assignments files')
    -- Every kind of frame was generated, many times.
    assert(seen.polls == FRAMES and seen.untrusted >= 100 and seen.pressed >= 5000 and seen.released >= 5000
           and seen.unavailable >= 500 and seen.page_reads >= 150 and seen.moved >= 30 and failed >= 100
           and sweeps.b >= 100, string.format('coverage: %d untrusted, %d pressed, %d released, %d unavailable, %d '
           .. 'page reads, %d moved, %d unreadable stretches, %d sweeps by poll', seen.untrusted, seen.pressed,
           seen.released, seen.unavailable, seen.page_reads, seen.moved, failed, sweeps.b))
    print(string.format('Differential over %d generated frames: poll answers as is_down for each id in order, the same '
          .. 'sweeps (%d by the caller), binding maps, swept counts, log lines (%d) and assignments files; edges as '
          .. 'defined (%d pressed, %d released, %d frames without edges); %d unavailable answers, %d answers on a '
          .. 'binding page after the player\'s change, %d records moved, %d unreadable stretches OK', FRAMES, sweeps.b,
          #a.lines, seen.pressed, seen.released, seen.untrusted, seen.unavailable, seen.page_reads, seen.moved, failed))
end

-- 3. No allocation per call once out's arrays hold every position, interpreted
-- and compiled: states changing, an unregistered id (nil) and the input owner
-- gone on some calls (nil where a state was read). The interpreted windows
-- must all be empty; the compiled ones are judged by their median, since a
-- trace compiled during a window counts as garbage there.
do
    local ids_all = {'map', 'missing', 'armory', 'auto.1', 'auto.2'}
    local garbage_out, call = {}, 0
    -- The test's own writes allocate nothing either: a pointer made once.
    local owner_slot, owner_address = ffi.cast('uint64_t *', game.base + OWNER_SLOT), address_of(game.owner)
    local map_state, armory_state = state_byte(MAP), state_byte(ARMORY)
    local function poll_once()
        call = call + 1
        game.owner[map_state] = call % 3 == 0 and 1 or 0
        game.owner[armory_state] = call % 5 < 2 and 1 or 0
        owner_slot[0] = call % 17 == 0 and 0 or owner_address
        menu.poll(ids_all, garbage_out)
    end
    -- One loop for the warm-up and the windows, so the windows run the traces
    -- the warm-up compiled (a loop of its own would compile its own).
    local function run(calls)
        for _ = 1, calls do poll_once() end
    end
    local function windows(compiled)
        if compiled then jit.on() else jit.off() end
        jit.flush()
        run(5000)
        collectgarbage('collect')
        collectgarbage('stop')
        local bytes = {}
        for window = 1, 5 do
            local before = collectgarbage('count')
            run(1000)
            bytes[window] = (collectgarbage('count') - before) * 1024
        end
        collectgarbage('restart')
        jit.on()
        table.sort(bytes)
        return bytes
    end
    use(one)
    local interpreted, compiled = windows(false), windows(true)
    owner_present(game, true)
    assert(interpreted[5] == 0, string.format('interpreted polls allocated %d bytes per 1000', interpreted[5]))
    assert(compiled[3] == 0, string.format('compiled polls allocated %d bytes per 1000 (median)', compiled[3]))
    print('No allocation per poll, interpreted and compiled OK')
end
for index = 1, instances do
    for _, suffix in ipairs({'', '.bak', '.tmp'}) do
        os.remove(TEMP .. '/mbm-test-poll-' .. index .. '/ModBindingsMenu.assignments' .. suffix)
    end
end
