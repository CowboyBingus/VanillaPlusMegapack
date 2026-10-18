-- The waiting update (src) against the v1.7.1 update (tests/reference), side by
-- side over scripted frames: ship and mission phases, presses with an Arc
-- Thrower and other weapons, shots, respawns, identity and holder changes,
-- unreadable input and bindings, charge-array moves, record flag resets and
-- an error below the addon. Both run in worlds of their own fed the same
-- script; every charging-flag write is compared frame by frame, the record
-- writes, protection changes and log lines in order.
--
-- Intended differences, which the script keeps out of the frame comparison
-- and checks on their own:
--   * a mission is noticed on the next poll frame (up to 60 updates, 1 s at
--     60 FPS): after entering one the script waits 60 updates before a press;
--   * outside a mission the Fire input is not read (nothing can fire there);
--   * the charge record is revalidated every 60 updates instead of every 15:
--     a reset record flag is repaired up to 45 updates later (checked below);
--   * fewer timestamps (QueryPerformanceCounter) and reads, not compared.
--
--   luajit tests/test_equivalence.lua <new entry> <reference entry> [cycles | traces]
local new_source, old_source = assert(arg[1]), assert(arg[2])
local cycles = tonumber(arg[3]) or 16
local ffi = require('ffi')
local GAME, REGION, SIZE = 0x100000, 0x10000000, 0x120000
local TRIGGER, CHARGE, ENTITIES, FLAGS, CHARGED, ENTRIES = 0x20000, 0x30000, 0x40000, 0x50000, 0x60000, 0x70000
local WEAPON, SECOND = 0x80000, 0x81000
local PM, OWNER, AM, AVATAR, MODE = 0x20000000, 0x21000000, 0x23000000, 0x21f32f30, 0x27000000
local FINGERPRINT = '\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41'
local RESOURCE = '\xe6\x06\x73\x0f\xd5\x9c\xde\x96'
local SIGNATURE = '\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
local RECORD = 65536 - 8 - 168
local PAGE = 4096
local ZERO4 = '\0\0\0\0'

local function integer(value, kind)
    local x = ffi.new((kind or 'uint64_t') .. '[1]', value)
    return ffi.string(x, ffi.sizeof(x))
end
local function u(v) return integer(v, 'uint32_t') end
local function blob(size, values)
    local b = ffi.new('uint8_t[?]', size)
    for offset, bytes in pairs(values) do ffi.copy(b + offset, bytes, #bytes) end
    return ffi.string(b, size)
end
local function putf(buffer, offset, value)
    local v = ffi.new('float[1]', value); ffi.copy(buffer + offset, v, 4)
end
local function input_at(index) return AM + 0x150 + index * 0xa7aec + 0x1b68 + 9 * 32 end
-- Game build 25480438's module files and hashes, for the build gate.
local EXE = 0x7ff600000000
local FILES = {[EXE] = 'C:\\Game\\bin\\helldivers2.exe', [GAME] = 'C:\\Game\\data\\game\\game.dll'}
local function utf16(text) return (text:gsub('.', '%0\0')) end
local function hash_key(file) return 'sha256:' .. utf16(file) end
local BUILD_EXE = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
local BUILD_GAME = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'

-- One world: memory, Windows stubs, the addon loaded from source, and what
-- it did (events: {frame, kind, ...}).
local function new_world(source, label)
    local w = {label = label, clock = 0, frame = 0, events = {}, charge_writes = {},
               down = false, weapon = 'ordinary', second = false, charge = 0.5, engine_flag = 1,
               command = true, relocated = false, generation = 1, input_valid = true, held_time = 0.5,
               full_time = 1.2, mission = false, mission_type = 1, blocked = {}, below_raises = 0,
               input = input_at(1), stale_input = nil, protections = {}, local_bytes = {}}
    w.region = ffi.new('uint8_t[?]', SIZE)
    local region = w.region
    putf(region, RECORD, 1); putf(region, RECORD + 24, 1.1); putf(region, RECORD + 48, 1.2)
    putf(region, RECORD + 72, 0.7); putf(region, RECORD + 76, 1.4)
    ffi.copy(region + RECORD + 168, FINGERPRINT, #FINGERPRINT)
    local function put(a, b) for i = 1, #b do w.local_bytes[a + i - 1] = b:sub(i, i) end end
    w.put = put
    for rva, a in pairs({[0x3326468] = PM, [0x346bf98] = OWNER, [0x3326d20] = AM, [0x33266a0] = MODE}) do
        put(GAME + rva, integer(a))
    end
    put(PM + 0x84, u(2) .. u(2)); put(PM + 0x3a8, u(9)); put(PM + 0xe8, integer(0x24000000))
    put(0x24000000, blob(24, {[20] = '\1'}))
    w.avatar = blob(24, {[0] = '\x97\xfa\x4d\x29\x4d\x33\x1c\x4d', [8] = u(222), [12] = u(4194313), [20] = '\1'})
    put(AVATAR, w.avatar); put(AM + 0x6c, u(2)); put(AM + 0x118, integer(AVATAR))
    local function map(header, rows, key, index)
        put(header, integer(rows) .. u(8) .. u(0xffffffff) .. u(1))
        put(rows, string.rep('\255', 64)); put(rows + key % 8 * 8, u(key) .. u(index))
    end
    map(OWNER + 0xf22ec8, 0x25000000, 9, 1); map(AM + 0xf8, 0x25000100, 222, 1)
    put(GAME + 0x3326dc0, integer(0x26000000)); map(0x26000000 + 32, 0x25000200, 77, 1)
    put(0x26000000 + 64, integer(0x26000100)); put(0x26000100 + 48 + 4, u(222))
    function w.move_avatar(index)
        put(AM + 0x110, integer(index == 0 and AVATAR or 0)); put(AM + 0x118, integer(index == 1 and AVATAR or 0))
        put(0x25000100 + 222 % 8 * 8, u(222) .. u(index))
        w.stale_input = w.input
        w.input = input_at(index)
    end
    local function entry_base() return ENTRIES + (w.relocated and 0x10000 or 0) end
    local function memory(address, size)
        if address == MODE and size == 68 then
            return blob(68, {[8] = u(w.mission and 1 or 0), [0x40] = u(w.mission_type)})
        end
        if w.blocked[address] then return nil end
        if address == w.input + 8 and size == 4 then
            if not w.input_valid then return nil end
            return w.down and integer(w.held_time, 'float') or ZERO4
        end
        if w.stale_input and address == w.stale_input + 8 and size == 4 then return ZERO4 end
        if address == w.input then
            return w.input_valid and blob(32, {[8] = integer(w.down and w.held_time or 0, 'float')}) or nil
        end
        if w.local_bytes[address] then
            local b = {}
            for i = 0, size - 1 do
                if not w.local_bytes[address + i] then return nil end
                b[#b + 1] = w.local_bytes[address + i]
            end
            return table.concat(b)
        end
        if address >= REGION and address + size <= REGION + SIZE then
            return ffi.string(region + address - REGION, size)
        end
        if address == GAME + 0x755f90 then return SIGNATURE end
        if address == GAME + 0x3326660 then return integer(TRIGGER) end
        if address == GAME + 0x3326c20 then return integer(CHARGE) end
        if address == TRIGGER + 24 then
            return blob(72, {[0] = integer(2, 'uint32_t'), [40] = integer(ENTITIES), [64] = integer(FLAGS)})
        end
        if address >= FLAGS and address + size <= FLAGS + 2 then
            local flags = blob(2, {[(w.second and 1 or 0)] = w.command and '\1' or '\0'})
            return flags:sub(address - FLAGS + 1, address - FLAGS + size)
        end
        if address >= ENTITIES and address + size <= ENTITIES + 16 then
            local entities = blob(16, {[0] = integer(WEAPON), [8] = integer(SECOND)})
            return entities:sub(address - ENTITIES + 1, address - ENTITIES + size)
        end
        if address == WEAPON or address == SECOND then
            return blob(24, {[0] = (w.weapon == 'arc' and RESOURCE or 'ordinary'), [8] = u(77),
                             [16] = u(w.generation), [20] = '\1'})
        end
        if address == CHARGE + 16 then
            return blob(56, {[0] = integer(512, 'uint32_t'), [40] = integer(CHARGED), [48] = integer(entry_base())})
        end
        if address >= CHARGED and address + size <= CHARGED + 512 * 8 then
            local pointers = blob(512 * 8, {[510 * 8] = integer(SECOND), [(w.relocated and 3 or 511) * 8] = integer(WEAPON)})
            return pointers:sub(address - CHARGED + 1, address - CHARGED + size)
        end
        if address == entry_base() + 511 * 40 or address == entry_base() + 510 * 40 or address == entry_base() + 3 * 40 then
            local b = ffi.new('uint8_t[40]'); putf(b, 4, w.charge); putf(b, 8, w.full_time); b[12] = w.engine_flag
            return ffi.string(b, 40)
        end
        return nil
    end
    local function number(address)
        if type(address) ~= 'number' then address = tonumber(ffi.cast('uintptr_t', address)) end
        return address
    end
    local function event(...) w.events[#w.events + 1] = {w.frame, ...} end
    local function region_protection(address) return w.protections[math.floor((address - REGION) / PAGE)] or 2 end
    w.region_protection = region_protection
    local kernel = {}
    -- The build gate (bingus_memory.lua) asks for the executable (no name) and
    -- game.dll, then their file names; the hashes come from the session's
    -- shared table, seeded with build 25480438's below, so no file is read.
    function kernel.GetModuleHandleA(name) return ffi.cast('void *', name == nil and EXE or GAME) end
    function kernel.GetModuleFileNameW(module, path, capacity)
        local file = assert(FILES[tonumber(ffi.cast('uintptr_t', module))], 'file name of an unknown module')
        assert(#file < capacity)
        ffi.copy(path, utf16(file) .. '\0\0', #file * 2 + 2)
        return #file
    end
    function kernel.CreateFileW() return ffi.cast('void *', -1) end -- INVALID_HANDLE_VALUE
    function kernel.ReadFile() error('the test reads no module file', 0) end
    function kernel.CloseHandle() return 1 end
    function kernel.VirtualQuery() return 0 end -- bound by the gate's runtime copy, never called
    function kernel.GetCurrentProcess() return ffi.cast('void *', 1) end
    function kernel.QueryPerformanceFrequency(p) p[0] = 1000000; return 1 end
    function kernel.QueryPerformanceCounter(p) p[0] = w.clock % 4294967296; p[1] = math.floor(w.clock / 4294967296); return 1 end
    function kernel.GetTickCount64() return math.floor(w.clock / 1000) end
    function kernel.ReadProcessMemory(_, address, buffer, size, count)
        address, size = number(address), tonumber(size)
        local data = memory(address, size)
        if not data or #data ~= size then return 0 end
        ffi.copy(buffer, data, size); count[0] = size; count[1] = 0; return 1
    end
    function kernel.VirtualQueryEx(_, address, info)
        address = number(address)
        if address == 0 then info.base = ffi.cast('void *', 0); info.size = REGION; info.state = 0; return 48 end
        if address >= REGION and address < REGION + SIZE then
            local base = address == REGION and REGION or address - (address - REGION) % PAGE
            info.base = ffi.cast('void *', base); info.size = REGION + SIZE - base
            info.state = 0x1000; info.protection = region_protection(address); info.type = 0x20000; return 48
        end
        if address >= ENTRIES and address < ENTRIES + 0x20000 then
            info.base = ffi.cast('void *', address - address % PAGE); info.size = PAGE
            info.state = 0x1000; info.protection = 4; info.type = 0x20000; return 48
        end
        return 0
    end
    function kernel.VirtualProtectEx(_, address, size, protection, previous)
        address = number(address)
        local page = math.floor((address - REGION) / PAGE)
        previous[0] = w.protections[page] or 2
        w.protections[page] = tonumber(protection)
        event('protect', address, tonumber(protection))
        return 1
    end
    function kernel.WriteProcessMemory(_, address, data, size, written)
        address = number(address)
        assert(tonumber(size) == 1)
        local byte = ffi.string(data, 1):byte()
        if address >= REGION and address < REGION + SIZE then
            if region_protection(address) ~= 4 then return 0 end
            region[address - REGION] = byte
            event('record', address, byte)
        else
            w.charge_writes[w.frame] = (w.charge_writes[w.frame] or '') .. string.format('%x=%d;', address, byte)
        end
        written[0] = size; written[1] = 0; return 1
    end
    -- The addon binds its private names (atr1_*), the gate's runtime copy its
    -- own (bingus_memory1_*); both resolve to the stub of the Windows export.
    local private = setmetatable({}, {__index = function(proxy, symbol)
        local name = symbol:match('^atr1_(.+)$') or symbol:match('^bingus_memory1_(.+)$')
        rawset(proxy, symbol, kernel[name])
        return kernel[name]
    end})
    local function no_hashing() error('the test hashes no module file', 0) end
    local bcrypt = setmetatable({}, {__index = function() return no_hashing end})
    local bindings = setmetatable({load = function(name)
        if name == 'bcrypt' then return bcrypt end
        return private
    end}, {__index = ffi})
    local env = setmetatable({}, {__index = _G}); env._G = env
    env.BingusRuntime = {hashes = {[hash_key(FILES[EXE])] = BUILD_EXE, [hash_key(FILES[GAME])] = BUILD_GAME}}
    env.require = function(name) return name == 'ffi' and bindings or require(name) end
    env.CowboyBingusModLoader = {api = 1, open_log = function()
        return {write = function(_, text) event('log', text) end, flush = function() end}
    end}
    env.update = function()
        if w.below_raises > 0 then w.below_raises = w.below_raises - 1; error('engine update failed', 0) end
        return 1
    end
    env.shutdown = function() return 'shut' end
    w.env = env
    setfenv(assert(loadfile(source)), env)()
    function w.tick()
        w.frame = w.frame + 1
        w.clock = w.clock + 16667
        pcall(env.update, 0.016667)
    end
    return w
end

-- Trace aborts in the addon's own code over idle updates (ship, then a
-- mission) and a held Arc Thrower. The guard runs the step under pcall, so a
-- trace started at the guarded step's entry aborts where it returns ("NYI:
-- return to lower frame"); a compiled helper called from an interpreted
-- function aborts where it returns into it. Control: v1.7.1 does both. Apart:
-- a trace the shared runtime's update starts stops at the guarded step's
-- entry (interpreted); LuaJIT blacklists that start after a few tries.
if arg[3] == 'traces' then
    if not (jit and jit.attach and jit.status()) then print('SKIP: no JIT'); return end
    local function aborts(source)
        local w = new_world(source, source)
        local function drive(n) for _ = 1, n do w.tick() end end
        jit.off(drive)
        drive(200) -- startup: scan and patch, interpreted warm-up
        local chunk = '@' .. source
        local boundary = 0 -- the line of 'local function guarded_step()'
        local number = 0
        for line in io.lines(source) do
            number = number + 1
            if line:find('^local function guarded_step%(%)') then boundary = number end
        end
        assert(boundary > 0)
        local count, at_boundary, reasons = 0, 0, {}
        local function on_trace(what, _, func, pc, code, detail)
            if what ~= 'abort' then return end
            local info = require('jit.util').funcinfo(func, pc)
            if info.source == chunk and info.currentline == boundary then
                at_boundary = at_boundary + 1
            elseif info.source == chunk then
                count = count + 1
                local okv, vmdef = pcall(require, 'jit.vmdef')
                local text = okv and vmdef.traceerr[code] or ('error ' .. tostring(code) .. ' ' .. tostring(detail))
                if okv and text:find('%%') then text = string.format(text, detail) end
                local key = text .. ' @' .. tostring(info.currentline)
                reasons[key] = (reasons[key] or 0) + 1
            end
        end
        jit.attach(on_trace, 'trace')
        drive(1500)
        w.mission = true; drive(1500)
        w.weapon = 'arc'; w.engine_flag = 0; w.down = true; drive(600); w.down = false; drive(300)
        jit.attach(on_trace)
        local list = {}
        for key, n in pairs(reasons) do list[#list + 1] = n .. 'x ' .. key end
        table.sort(list)
        return count, table.concat(list, '; '), at_boundary
    end
    local control, why_control = aborts(old_source)
    local count, why, at_boundary = aborts(new_source)
    assert(control > 0, 'control: v1.7.1 did not abort, so this test proves nothing')
    assert(count == 0, count .. ' trace aborts in the addon (' .. why .. '); v1.7.1: ' .. control)
    assert(at_boundary <= 3, at_boundary .. ' aborts at the guarded step entry: the start is not blacklisted')
    print('PASS: no trace aborts in the addon over 3,900 updates, ' .. at_boundary
          .. ' at the guard boundary (v1.7.1: ' .. control .. ': ' .. why_control .. ')')
    return
end

local worlds = {new_world(new_source, 'new'), new_world(old_source, 'v1.7.1')}
local new, old = worlds[1], worlds[2]
local function each(f) for _, w in ipairs(worlds) do f(w) end end
-- Both passed the build gate: the first log line is the start on build 25480438.
each(function(w)
    local first = w.events[1]
    assert(first and first[2] == 'log' and first[3]:find('initialised on game build 25480438', 1, true),
           w.label .. ' did not start: ' .. tostring(first and first[3]))
end)
local function set(field, value) each(function(w) w[field] = value end) end
local frames, compared, presses, arc_writes = 0, 0, 0, 0
local mission_frames, ship_frames = 0, 0
local function tick(compare)
    frames = frames + 1
    each(function(w) w.tick() end)
    if new.mission then mission_frames = mission_frames + 1 else ship_frames = ship_frames + 1 end
    local a, b = new.charge_writes[frames], old.charge_writes[frames]
    if a then arc_writes = arc_writes + 1 end
    if compare ~= false then
        compared = compared + 1
        assert(a == b, string.format('frame %d: charging-flag writes differ: new %s, v1.7.1 %s',
                                     frames, tostring(a), tostring(b)))
    end
end
local function ticks(n, compare) for _ = 1, n do tick(compare) end end

-- A small deterministic generator, so every run scripts the same frames.
local seed = 12345
local function random(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end

-- One mission: up to 60 updates for the waiting update to notice it, then
-- random play. Every step holds for a few updates.
local function play(steps)
    for _ = 1, steps do
        local roll = random(100)
        if roll < 30 then
            set('down', not new.down)
            if new.down then
                presses = presses + 1; set('held_time', 0.5)
                if random(3) > 0 then -- most presses: an Arc Thrower the engine fires
                    set('weapon', 'arc'); set('command', true); set('input_valid', true)
                    each(function(w) w.blocked = {} end)
                end
            end
        elseif roll < 40 then set('weapon', new.weapon == 'arc' and 'ordinary' or 'arc')
        elseif roll < 50 then set('engine_flag', 1 - new.engine_flag)
        elseif roll < 58 then set('charge', ({0, 0.3, 0.8, 1.2, 0.05})[random(5) + 1])
        elseif roll < 63 then set('command', not new.command)
        elseif roll < 67 then set('second', not new.second)
        elseif roll < 71 then set('relocated', not new.relocated)
        elseif roll < 74 then set('input_valid', not new.input_valid)
        elseif roll < 77 then
            local index = new.input == input_at(1) and 0 or 1 -- a respawn
            each(function(w) w.move_avatar(index) end)
        elseif roll < 79 then set('generation', new.generation + 1)
        elseif roll < 82 then
            local address = ({WEAPON, 0x26000100 + 48 + 4, CHARGE + 16})[random(3) + 1]
            each(function(w) w.blocked[address] = not w.blocked[address] or nil end)
        elseif roll < 84 then
            each(function(w) w.put(0x26000100 + 48 + 4, u(random(2) == 0 and 999 or 222)) end)
        elseif roll < 86 then
            set('held_time', 0.01) -- an interrupted hold: the held time went back
        end
        ticks(1 + random(20))
        set('held_time', new.held_time + 0.1)
    end
    -- End of the mission: release everything, give the bindings back.
    set('down', false); set('input_valid', true); set('weapon', 'ordinary'); set('command', true)
    each(function(w) w.blocked = {}; w.put(0x26000100 + 48 + 4, u(222)) end)
    ticks(30)
end

-- The record flag reset mid-mission: v1.7.1 repairs it on its next check frame
-- (every 15 updates), the waiting update on its next poll frame (every 60).
local function record_reset()
    each(function(w) w.region[RECORD + 184] = 0 end)
    local repaired = {}
    for frame = 1, 60 do
        tick()
        for _, w in ipairs(worlds) do
            if not repaired[w] and w.region[RECORD + 184] == 1 then repaired[w] = frame end
        end
    end
    assert(repaired[new] and repaired[old], 'a reset record flag is repaired within 60 updates: new '
           .. tostring(repaired[new]) .. ', v1.7.1 ' .. tostring(repaired[old]) .. ' at update ' .. frames)
    assert(repaired[old] <= 15 and repaired[new] <= 60 and repaired[new] >= repaired[old])
    return repaired[new] - repaired[old]
end

ticks(200, false) -- startup on the ship: scan, patch
for cycle = 1, cycles do
    -- On the ship: Fire pressed with no Arc Thrower and no fire command.
    set('command', false); set('down', true); ticks(40); set('down', false); ticks(20); set('command', true)
    set('mission', true)
    ticks(60, false) -- the waiting update notices the mission by its next poll frame
    play(40 + random(40))
    if cycle % 3 == 0 then record_reset() end
    if cycle % 4 == 0 then
        -- An error below: both put the record back and pause for 60 updates.
        set('below_raises', 1); ticks(70)
    end
    set('mission', false)
    ticks(60 + random(60))
end

-- Same record writes and protection changes, in order, and the same log.
local function list(w, kind)
    local out = {}
    for _, e in ipairs(w.events) do
        if e[2] == kind then out[#out + 1] = table.concat({tostring(e[3]), tostring(e[4])}, ' ') end
    end
    return out
end
for _, kind in ipairs({'record', 'protect', 'log'}) do
    local a, b = list(new, kind), list(old, kind)
    assert(#a == #b, kind .. ': ' .. #a .. ' in the waiting update, ' .. #b .. ' in v1.7.1')
    for i = 1, #a do assert(a[i] == b[i], kind .. ' #' .. i .. ' differs: ' .. a[i] .. ' / ' .. b[i]) end
end
for _, line in ipairs(list(new, 'log')) do
    assert(not line:find('error', 1, true) and not line:find('stopped', 1, true), 'unexpected log line: ' .. line)
end
assert(presses > 100 and arc_writes > 1000,'the script must exercise the assist: ' .. presses .. ' presses, '
       .. arc_writes .. ' frames with writes')
each(function(w) w.env.shutdown() end)
assert(new.region[RECORD + 184] == old.region[RECORD + 184])
print(string.format('PASS: equivalence over %d updates (%d compared frame by frame; %d in missions, %d outside), '
                    .. '%d presses, %d frames with charging-flag writes, %d record writes, %d log lines',
                    frames, compared, mission_frames, ship_frames, presses, arc_writes, #list(new, 'record'),
                    #list(new, 'log')))
