-- Match Your Colors: the 2026-10-17 idle-read changes against v1.5 (tests/reference/: avatar.lua, preview.lua and
-- weapons.lua as published in the v1.5 pre-release), side by side:
--   * the body-copy slot read covers only the entries in use at the last read (v1.5: all 16, 2,116 bytes);
--   * the UI preview poll reads the gate's 16 bytes while no player slot showed (v1.5: the 1,296-byte span);
--   * the weapon binding compared as two 32-bit halves (v1.5: decoded from bytes).
-- Every result of the three watches is compared over thousands of scripted frames (changes, growth and shrinking,
-- unreadable memory, retargets), then two whole instances (v1.5's modules and the new ones) run the same scripted
-- game for thousands of frames: log, job requests, bindings and visibility equal on every frame, and the reads equal
-- except one more on a frame where the copy slot's count grew.
-- Usage: luajit tests/test_idle_equivalence.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_idle_equivalence.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Fake = dofile(root .. '/tests/fake_game.lua')
local Old = {Avatar = dofile(root .. '/tests/reference/avatar.lua'), Preview = dofile(root .. '/tests/reference/preview.lua'),
             Weapons = dofile(root .. '/tests/reference/weapons.lua')}
local New = {Avatar = require('avatar'), Preview = require('preview'), Weapons = require('weapons')}
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
    print('  ok: ' .. name)
end

-- Park-Miller (exact in doubles).
local seed = 20261017
local function random(n)
    seed = seed * 16807 % 2147483647
    return seed % n
end
local function chance(percent) return random(1000) < percent * 10 end

-- A memory over a Fake.space whose reads fail while `blocked` names the address range.
local function memory_over(space)
    local m = {blocked = {}, reads = 0}
    local cell = ffi.new('union { const void *pointer; struct { uint32_t low, high; }; }')
    function m.read_into(pointer, size, out)
        local address = pointer
        if type(pointer) ~= 'number' then
            cell.pointer = pointer
            address = cell.low + cell.high * 4294967296
        end
        m.reads = m.reads + 1
        if size == 16 then m.gate_reads = (m.gate_reads or 0) + 1 end
        for _, b in ipairs(m.blocked) do
            if address < b[2] and address + size > b[1] then return false end
        end
        return space.read_into(pointer, size, out)
    end
    return m
end

check('Avatar.watch: the same changes and unit refs over 20,000 frames (slot grows, shrinks, unreadable)', function()
    local space = Fake.space()
    local UNITS, SLOT = 0x1000, 0x2000
    space.region(UNITS, 120)
    space.region(SLOT, 64 + 2116)
    local memory = memory_over(space)
    local old, new
    local function adopt()
        old = Old.Avatar.watch(memory, {units_at = UNITS}, SLOT)
        new = New.Avatar.watch(memory, {units_at = UNITS}, SLOT)
    end
    adopt()
    local differences, grown = 0, 0
    for frame = 1, 20000 do
        if chance(3) then space.u32(UNITS + 4 * random(30), random(4) == 0 and 0xFFFFFFFF or random(8)) end
        if chance(2) then
            local count = random(10) < 7 and random(4) or random(20)
            space.u32(SLOT + 64, count)
        end
        if chance(4) then space.byte(SLOT + 68 + random(2112), random(256)) end
        if chance(1) then memory.blocked = {} end
        if chance(0.5) then memory.blocked = {{UNITS, UNITS + 120}} end
        if chance(0.5) then memory.blocked = {{SLOT + 64, SLOT + 64 + 2116}} end
        -- Not scripted: unused entries unreadable while the count and the entries in use read. v1.5 saw every read of
        -- such a slot fail (a change, a chain check every other frame), the new read does not cover them. It cannot
        -- happen in the game: the 2,116 bytes lie inside one 2,184-byte slot of the Previews array.
        if chance(0.3) then adopt() end
        local copies = frame % 2 == 1
        local r0 = memory.reads
        local a = old.changed(copies)
        local r1 = memory.reads
        local b = new.changed(copies)
        local r2 = memory.reads
        if (r2 - r1) == (r1 - r0) + 1 then grown = grown + 1 end
        assert(r2 - r1 <= r1 - r0 + 1, 'at most one more read')
        if a ~= b then differences = differences + 1 end
        for i = 0, 29 do assert(old.ref(i) == new.ref(i), 'frame ' .. frame .. ': ref ' .. i) end
        assert(a == b, string.format("frame %d: changed %s (v1.5) vs %s; blocked %s", frame, tostring(a), tostring(b), memory.blocked[1] and string.format("%x-%x", memory.blocked[1][1], memory.blocked[1][2]) or "none"))
    end
    assert(differences == 0 and grown > 50, 'growth frames exercised: ' .. grown)
end)

check('Preview.watch: the same statuses, kits, changes and ring over 20,000 frames (mostly nothing shown)', function()
    local space = Fake.space()
    local SYSTEM = 0x5000000
    local FIRST = SYSTEM + 49160
    space.region(FIRST, 1296)
    local memory = memory_over(space)
    local function where(slot) return New.Preview.retarget({system = SYSTEM, first = FIRST}, slot) end
    local w_old, w_new = where(1), where(1)
    local old, new = Old.Preview.watch(memory, w_old), New.Preview.watch(memory, w_new)
    local mask, fast, gates = 0, 0, 0
    for frame = 1, 20000 do
        if chance(1.5) then
            mask = random(3) == 0 and random(256) or 0 -- long runs with no slot shown
            space.u32(FIRST + 1280 + 4, mask)
            local count = 0
            for s = 0, 7 do if math.floor(mask / 2 ^ s) % 2 == 1 then count = count + 1 end end
            space.u32(FIRST + 1280, chance(10) and 9 + random(3) or count)
        end
        if chance(3) then space.u32(FIRST + 1280 + 8, random(64)) end -- the weapon ring's head
        if chance(5) then space.byte(FIRST + 160 * random(4) + 12 + random(140), random(256)) end
        if chance(0.5) then memory.blocked = {} end
        if chance(0.2) then memory.blocked = {{FIRST, FIRST + 1296}} end
        if chance(0.2) then memory.blocked = {{FIRST + 1280, FIRST + 1296}} end
        if chance(0.3) then
            local s = random(4)
            New.Preview.retarget(w_old, s)
            New.Preview.retarget(w_new, s)
            old.reset()
            new.reset()
        end
        local r0 = memory.reads
        local a, b = old.poll(), new.poll()
        if memory.reads - r0 == 2 and (memory.gate_reads or 0) > gates then fast = fast + 1 end -- the gate alone
        gates = memory.gate_reads or 0
        assert(a == b, string.format('frame %d: status %s vs %s', frame, tostring(a), tostring(b)))
        assert(old.changes == new.changes and old.ring_moved() == new.ring_moved(), 'frame ' .. frame .. ': changes, ring')
        for s = 0, 3 do
            assert(old.status(s) == new.status(s), 'frame ' .. frame .. ': status of slot ' .. s)
            local h1, a1, b1, c1 = old.slot_kits(s)
            local h2, a2, b2, c2 = new.slot_kits(s)
            assert(h1 == h2 and a1 == a2 and b1 == b2 and c1 == c2, 'frame ' .. frame .. ': kits of slot ' .. s)
        end
    end
    assert(fast > 5000, 'the gate-only poll exercised: ' .. fast)
end)

check('Weapons.watch: the same binding and row results over 20,000 frames', function()
    local space = Fake.space()
    local ROW, ENTRY = 0x6000000, 0x6100000
    space.region(ROW, 48)
    space.region(ENTRY, 16)
    local memory = memory_over(space)
    local old, new = Old.Weapons.watch(memory, {row = ROW}), New.Weapons.watch(memory, {row = ROW})
    local low, high, held = 0x70000000, 0x1, 0
    for frame = 1, 20000 do
        if chance(5) then space.u32(ENTRY + random(2) * 4, random(3) == 0 and low or random(0x100000000)) end
        if chance(3) then space.u32(ENTRY + 4, high) end
        if chance(2) then space.u32(ENTRY, low) end
        if chance(1) then low, high = random(0x100000000), random(0x10000) end
        if chance(3) then space.byte(ROW + random(48), random(256)) end
        if chance(0.5) then memory.blocked = {} end
        if chance(0.3) then memory.blocked = {{ENTRY, ENTRY + 8}} end
        local entry = chance(1) and ENTRY + 8 or ENTRY
        assert(old.bound(entry, low, high) == new.bound(entry, low, high), 'frame ' .. frame .. ': bound')
        if frame % 4 == 2 then
            assert(old.row_changed() == new.row_changed() and old.held() == new.held(), 'frame ' .. frame .. ': row')
            if old.held() ~= held then held = old.held() end
        end
    end
end)

-- Two instances: one over v1.5's three modules, one over the new ones (tests/test_addon.lua's world and canned job,
-- loaded once per side).
local function load_side(modules)
    for name, m in pairs({avatar = modules.Avatar, preview = modules.Preview, weapons = modules.Weapons}) do
        package.loaded[name] = m
    end
    rawset(_G, 'MYC_TEST_SETUP_ONLY', true) -- lint-ok: R8 test process only
    local setup, requests, helpers = dofile(root .. '/tests/test_addon.lua')
    rawset(_G, 'MYC_TEST_SETUP_ONLY', nil) -- lint-ok: R8 test process only
    return setup, requests, helpers
end
local old_setup, old_requests, old_helpers = load_side(Old)
local new_setup, new_requests, new_helpers = load_side(New)

local HELMET_LUT = '962a946e964ebc40'
local WEAPON = {id = 0x301, name = '968211c0033dce64', unit = 0x400, units = {}, attachments = {}}
local UNITS = {0x100, 0x101, 0x102, 0x103, 0x105, 0x106, 0x300, 0x301, 0x302, 0x400}
local LOCAL_ID = 'C0FFEE5EED0001'

local function world(make, helpers, options)
    local w = make(options)
    helpers.weapon_luts[WEAPON.name] = {HELMET_LUT}
    for _, unit in ipairs({0x105, 0x300, 0x301, 0x302, 0x400}) do w.engine.unit(unit, HELMET_LUT) end
    if options.weapons then
        w.weapons.set(1, WEAPON)
        w.instance.set_option('recolor_weapons', true)
    end
    if options.lobby then w.instance.set_option('squad', 3) end
    return w
end

-- Every observable of a world after a frame, as one string.
local function observe(w, requests)
    local parts = {#w.lines, #requests, requests[#requests] and tostring(requests[#requests].target) or '-'}
    for _, unit in ipairs(UNITS) do
        if w.engine.units[unit] then
            for _, b in ipairs(w.bound(unit)) do parts[#parts + 1] = string.format('%x', b) end
            parts[#parts + 1] = w.engine.hidden(unit) and 'h' or 's'
        end
    end
    return table.concat(parts, ' ')
end

-- One scripted event, the same on both worlds.
local KITS = {{helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0}, {helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0},
              {helmet = 0x0b0b0b0b, armor = 0x22222222, body = 0}}
local COPY_COUNT = Fake.PREVIEWS + 2080 + 2184 + 64 -- the local player's body-copy slot (Fake.world slot 1)
local function event(worlds, options)
    local roll = random(100)
    local kits, n, unit = KITS[random(#KITS) + 1], random(4), random(2) == 0 and 0x100 or 0x105
    for _, w in ipairs(worlds) do
        local s = w.space
        if roll < 15 and options.ui then
            Fake.show_ui(s, Fake.UI_SLOTS[1], kits, {[{0, 0}] = 0x300, [{0, 2}] = 0x301})
        elseif roll < 30 and options.ui then
            Fake.show_ui(s, Fake.UI_SLOTS[1], nil)
        elseif roll < 38 and options.ui then
            Fake.show_ui(s, n == 0 and 0 or 3, n % 2 == 0 and kits or nil, {[{0, 0}] = 0x302})
        elseif roll < 50 then
            s.u32(Fake.local_unit_at(0, 0), unit)
        elseif roll < 62 and options.previews then
            s.u32(COPY_COUNT, n)
            for k = 0, n - 1 do s.u32(Fake.preview_entry_at(1, k) + 12, unit) end
        elseif roll < 70 and options.weapons then
            w.weapons.hold(n % 2)
        elseif roll < 76 then
            s.u32(Fake.CUSTOMIZATION + 2416, kits.helmet)
        end
    end
end

local function side_by_side(options, frames)
    seed = 4242 + frames
    local a = world(old_setup, old_helpers, options)
    local b = world(new_setup, new_helpers, options)
    local grown = 0
    for frame = 1, frames do
        if frame % 7 == 0 then event({a, b}, options) end
        local fa, fb = a.frame(), b.frame()
        local ra, rb = fa.read_into or 0, fb.read_into or 0
        if rb == ra + 1 then grown = grown + 1 end
        -- one more read: the copy slot's count grew, or a UI preview slot appeared after the gate's 16 bytes
        assert(rb == ra or rb == ra + 1, string.format('frame %d: reads %d vs %d', frame, ra, rb))
        for k, v in pairs(fa) do if k ~= 'read_into' then assert(fb[k] == v, 'frame ' .. frame .. ': ' .. k) end end
        for k in pairs(fb) do assert(fa[k] ~= nil or k == 'read_into', 'frame ' .. frame .. ': ' .. k) end
        local oa, ob = observe(a, old_requests), observe(b, new_requests)
        assert(oa == ob, string.format('frame %d:\n  v1.5 %s\n  new  %s', frame, oa, ob))
    end
    -- the Lua heap's growth over a job is the process's (two instances share it), not the mod's decision
    local function plain(line) return (line:gsub('heap [+-]%d+ KB', 'heap')) end
    for i = 1, #a.lines do
        assert(plain(a.lines[i]) == plain(b.lines[i]), 'log line ' .. i .. ': ' .. a.lines[i] .. ' / ' .. b.lines[i])
    end
    assert(#a.lines == #b.lines and #a.lines > 5, 'the same log')
    return grown, #a.lines
end

check('two instances, previews + UI + weapons: the same log, jobs, bindings and calls over 6,000 frames', function()
    local grown, lines = side_by_side({previews = true, ui = true, weapons = true}, 6000)
    print(string.format('    %d log lines; %d frames made one more read', lines, grown))
end)

check('two instances, UI + a squadmate sharing (sync): the same over 3,000 frames', function()
    local grown, lines = side_by_side({ui = true, lobby = {local_id = LOCAL_ID,
        members = {{id = LOCAL_ID}, {id = '1234', value = 'v=1;m=2;f=3;s=0;'}}}}, 3000)
    print(string.format('    %d log lines', lines))
end)

check('idle frames read no 1,296-byte span (no UI preview shown) and no 2,116-byte slot (no copy in it)', function()
    seed = 99
    local w = world(new_setup, new_helpers, {previews = true, ui = true, weapons = true})
    w.weapons.hold(1)
    w.frames(240)
    local sizes = {}
    local read_into = w.memory.read_into
    w.memory.read_into = function(pointer, size, out)
        sizes[size] = (sizes[size] or 0) + 1
        return read_into(pointer, size, out)
    end
    w.frames(120)
    w.memory.read_into = read_into
    assert(not sizes[1296] and not sizes[2116], 'no large idle read')
    assert(sizes[16] >= 30 and sizes[4] >= 60 and sizes[120] >= 120, 'the gate on 1 frame in 4, the slot count on odd frames')
end)

print('PASS test_idle_equivalence (' .. passed .. ' checks)')
