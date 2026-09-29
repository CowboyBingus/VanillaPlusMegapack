-- Nearby lobbies (src/region.lua): the game's key combine against keys read
-- from the live override tables, flipping and adding flags for the player's
-- continent in one write, leaving the peer-synced table alone, restoring the
-- table byte for byte, following config downloads, and the per-frame cost.
-- Usage: test_region.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local R = dofile(source .. '/region.lua')
local ffi = require('ffi')

-- Keys and row keys read from the running game (build 25480438).
local id = {}
for index, continent in ipairs(R.CONTINENTS) do id[continent[1]] = {index = index, id = continent[2]} end
local function pair(own, other) return R.combine({R.KEY_WORDS[1], R.KEY_WORDS[2], id[own].id, id[other].id}) end
local LIVE, ROW_KEYS = Fake.LIVE_PAIRS, Fake.ROW_KEYS
for _, case in ipairs(LIVE) do
    assert(pair(case[1], case[2]) == case[3], string.format('%s->%s: %08x', case[1], case[2], pair(case[1], case[2])))
end
for name, key in pairs(ROW_KEYS) do assert(R.ROWS[id[name].index].key == key, name .. ' row key') end
for own, row in ipairs(R.ROWS) do
    assert(#row == 6 and row.name == R.CONTINENTS[own][1])
    for _, entry in ipairs(row) do assert(entry.key == pair(row.name, entry.name) and entry.id == id[entry.name].id) end
end
assert(R.combine({0x673bc524, 0x244e3796}) == 0xa6eb4f53 and R.combine({0x673bc524, 0x2f5e2854}) == 0xf5007569)
math.randomseed(7)
for _ = 1, 2000 do
    local a, b = math.random(0, 4294967295), math.random(0, 4294967295)
    assert(R.mul32(a, b) == tonumber((ffi.cast('uint64_t', a) * b) % 4294967296ULL))
end
print('PASS: key combine reproduces the 16 live pair keys, 6 row keys and two config keys; mul32 is exact')

-- A simulated config object laid out like the game's (tests/fake_game.lua).
local SERVER_CHECKSUM = Fake.SERVER_CHECKSUM
local function build_world(options)
    local world = Fake.new({G = G, R = R})
    Fake.install_config(world, R, options)
    local natives = G.bind(world.api, Fake.GAME, Fake.EXE)
    local status, lines = {}, {}
    local region = R.new(world.api, Fake.GAME, natives, status, function(message) lines[#lines + 1] = message end)
    return world, region, status, lines
end

-- What the search builder sees: the pair's flag through the game's lookup order.
local function flag(world, own, other)
    for _, header in ipairs({world.synced, world.main}) do
        local entry = R.lookup(world.api, header, pair(own, other))
        if entry then return world.get32(entry + 24) % 256, world.get32(entry + 20), entry end
    end
end
local function excluded(world, own) return world.excluded(own) end
local function snapshot(world, header)
    local words = {}
    for address = header, header + R.CHECKSUM, 4 do words[#words + 1] = world.get32(address) end
    return words
end
local function same(a, b)
    for i = 1, math.max(#a, #b) do
        if a[i] ~= b[i] then return false, string.format('word %d: %s vs %s', i, tostring(a[i]), tostring(b[i])) end
    end
    return true
end
local function run_checks(region, frames) for _ = 1, frames do region.step() end end

-- Own continent only (NA): EU flipped, AN added, SA left to the peer-synced
-- table; one page check; everything else untouched.
do
    local world, region, status, lines = build_world({extra = {{'NA', 'EU', 1}}, synced = {{'NA', 'SA', 1}}})
    assert(region.verify() and region.continent() == id.NA.index)
    assert(excluded(world, 'NA') == 'AF AS OC', excluded(world, 'NA'))
    local before, synced_before = snapshot(world, world.main), snapshot(world, world.synced)
    local count_before = world.get32(world.main + R.COUNT)
    local captured
    local write_words = world.api.write_words
    world.api.write_words = function(address, size, words) captured = {address = address, size = size, words = words}
        return write_words(address, size, words) end
    local counts = budget.wrap(world.api)
    local frame, ok = budget.frame(counts, region.set_mode, 2)
    assert(ok and status.region == 'my continent only (NA)', status.region)
    -- The apply frame (option switched on): one page check for every write.
    budget.check(frame, {load8 = 9, load32 = 75, load64 = 16, read32 = 6, read64 = 2, writable_data = 1,
                         write_words = 1}, 'apply frame')
    assert(frame.writable_data == 1)
    assert(captured.address == world.main and captured.size == R.SPAN and R.SPAN == 0x6020)
    assert(excluded(world, 'NA') == 'AF AN AS EU OC', excluded(world, 'NA'))
    assert(flag(world, 'NA', 'SA') == 1, 'the peer-synced SA flag answers first and is left alone')
    assert(same(snapshot(world, world.synced), synced_before), 'peer-synced table never written')
    assert(excluded(world, 'EU') == 'SA' and excluded(world, 'AF') == 'NA OC SA', 'other rows untouched')
    assert(world.get32(world.main + R.CHECKSUM) == SERVER_CHECKSUM, 'stored checksum unchanged')
    assert(world.get32(world.main + R.COUNT) == count_before + 1, 'count includes the added entry')
    -- The added entry looks like the server's own.
    local _, _, entry = flag(world, 'NA', 'AN')
    local key = pair('NA', 'AN')
    local expect = {key, 0, id.AN.id, ROW_KEYS.NA, key, R.TYPE_BOOL, 0, 0, 0, 0, R.WEIGHT, 0}
    for i, value in ipairs(expect) do assert(world.get32(entry + (i - 1) * 4) == value, 'added entry word ' .. i) end
    -- Key last in each added entry, the count after every entry.
    local position = {}
    for i = 1, #captured.words, 2 do position[captured.words[i]] = i end
    local o = entry - world.main
    for field = 4, 44, 4 do assert(position[o + field] < position[o], 'field before key') end
    assert(position[R.COUNT] == #captured.words - 1, 'count written last')
    assert(lines[#lines - 1]:find('NA%->SA set by the peer%-synced config') and
        lines[#lines] == 'nearby lobbies: own continent only, 2 flags written', lines[#lines])
    -- Off again: the table is byte-identical to the server's.
    frame = budget.frame(counts, region.set_mode, 1)
    assert(frame.writable_data == 1, budget.describe(frame))
    local equal, where = same(snapshot(world, world.main), before)
    assert(equal, 'restored byte for byte: ' .. tostring(where))
    assert(status.region == 'game default' and lines[#lines] == 'nearby lobbies: game default, 2 flags restored')
    assert(excluded(world, 'NA') == 'AF AS OC')
    -- And on again.
    assert(region.set_mode(2) and excluded(world, 'NA') == 'AF AN AS EU OC')
end
print('PASS: own continent only flips server flags and adds missing ones in one write, never touches the synced table')

-- Other continents: SA adds AN and NA; AN (no server row) adds all six.
do
    local world, region = build_world({code = 'SA'})
    assert(region.set_mode(2) and excluded(world, 'SA') == 'AF AN AS EU NA OC', excluded(world, 'SA'))
    world, region = build_world({code = 'AN'})
    local before = snapshot(world, world.main)
    assert(region.set_mode(2) and excluded(world, 'AN') == 'AF AS EU NA OC SA', excluded(world, 'AN'))
    assert(world.get32(world.main + R.COUNT) == 17 + 6)
    region.set_mode(1)
    assert(same(snapshot(world, world.main), before))
end
print('PASS: every continent gets all six exclusions; adding six entries restores cleanly')

-- Per-frame cost: nothing while off; nothing between checks; a check with the
-- flags in place is direct loads only.
do
    local world, region = build_world({})
    local counts = budget.wrap(world.api)
    budget.check(budget.frame(counts, region.step), {}, 'region off')
    region.set_mode(2)
    local check_frame
    for frame_index = 1, 3 * R.VERIFY_FRAMES do
        local frame = budget.frame(counts, region.step)
        if frame_index % R.VERIFY_FRAMES == 0 then
            check_frame = frame
            budget.check(frame, {load8 = 6, load32 = 5, load64 = 1}, 'region check frame')
        else
            budget.check(frame, {}, 'region on, between checks')
        end
    end
    print('INFO: region check frame every ' .. R.VERIFY_FRAMES .. ' frames: ' .. budget.describe(check_frame))
end
print('PASS: region costs nothing while off and between checks; a check is direct loads only (no system calls)')

-- Config downloads.
do
    -- Unchanged download: the game keeps the table (same checksum), so nothing is written.
    local world, region, status, lines = build_world({})
    region.set_mode(2)
    local counts = budget.wrap(world.api)
    local page_checks = 0
    for _ = 1, 2 * R.VERIFY_FRAMES do page_checks = page_checks + (budget.frame(counts, region.step).writable_data or 0) end
    assert(page_checks == 0)
    -- Changed download: the new table replaces ours; the next check writes again.
    world.download(0x0badc0de, {{'NA', 'EU', 1}})
    local server = snapshot(world, world.main)
    assert(excluded(world, 'NA') == 'AF AS OC')
    run_checks(region, R.VERIFY_FRAMES)
    assert(excluded(world, 'NA') == 'AF AN AS EU OC SA' and lines[#lines] == 'nearby lobbies: re-applied, 3 flags written',
        lines[#lines])
    region.set_mode(1)
    assert(same(snapshot(world, world.main), server), 'restores the new server table')
    -- Replaced before the next check: records are dropped, nothing is written.
    region.set_mode(2)
    world.download(0x12345678)
    local fresh = snapshot(world, world.main)
    local frame = budget.frame(counts, region.set_mode, 1)
    assert((frame.writable_data or 0) == 0 and same(snapshot(world, world.main), fresh))
    assert(status.region == 'game default')
    -- Cleared and reloaded with the same content and checksum (sign out, sign in).
    region.set_mode(2)
    world.clear(world.main)
    run_checks(region, R.VERIFY_FRAMES)
    assert(status.region == 'my continent only: waiting (override data not loaded)', status.region)
    world.download(0x12345678)
    run_checks(region, R.VERIFY_FRAMES)
    assert(status.region == 'my continent only (NA)' and excluded(world, 'NA') == 'AF AN AS EU OC SA')
    region.set_mode(1)
    assert(same(snapshot(world, world.main), fresh))
end
print('PASS: flags survive unchanged downloads, come back after changed ones, and restore to whatever the server sent')

-- Waiting: unknown continent, refused writes, a full table, a changed layout, changed code.
do
    local world, region, status, lines = build_world({continent = false})
    assert(region.set_mode(2) == false and status.region == 'my continent only: waiting (continent unknown)')
    local notes = #lines
    run_checks(region, 3 * R.VERIFY_FRAMES)
    assert(#lines == notes, 'a waiting reason is logged once')
    world.continent = true
    run_checks(region, R.VERIFY_FRAMES)
    assert(status.region == 'my continent only (NA)' and excluded(world, 'NA') == 'AF AN AS EU OC SA')

    world, region, status = build_world({})
    world.readonly = true
    local counts = budget.wrap(world.api)
    local frame, ok = budget.frame(counts, region.set_mode, 2)
    assert(ok == false and frame.writable_data == 1 and status.region == 'my continent only: waiting (write refused)')
    local page_checks = 0
    for _ = 1, 3 * R.VERIFY_FRAMES do page_checks = page_checks + (budget.frame(counts, region.step).writable_data or 0) end
    assert(page_checks == 0, 'a refused write is not retried until the table changes')
    world.download(0x0badc0de)
    for _ = 1, R.VERIFY_FRAMES do page_checks = page_checks + (budget.frame(counts, region.step).writable_data or 0) end
    assert(page_checks == 1)
    world.readonly = false
    world.download(0x0badf00d)
    run_checks(region, R.VERIFY_FRAMES)
    assert(status.region == 'my continent only (NA)' and excluded(world, 'NA') == 'AF AN AS EU OC SA')

    world, region, status = build_world({})
    local filler = 1
    for slot = 0, R.CAPACITY - 1 do
        local entry = world.main + R.ENTRIES + slot * R.ENTRY_SIZE
        if world.get32(entry) == 0 then world.put32(entry, filler); filler = filler + 1 end
    end
    assert(region.set_mode(2) == false and status.region == 'my continent only: waiting (override table full)')
    assert(world.api.queries == 0)

    world, region, status = build_world({})
    world.put64(world.main, 0x1000)
    assert(region.set_mode(2) == false and status.region == 'my continent only: waiting (override table layout changed)')

    world, region = build_world({})
    world.put32(Fake.GAME + R.CONTINENT_IDS_RVA + 8, 0)
    local verified, why = region.verify()
    assert(verified == false and why == 'continent table changed')
    for _, code in ipairs(R.CODE) do
        world, region = build_world({})
        world.changed = Fake.GAME + code.rva
        verified, why = region.verify()
        assert(verified == false and why == code.name .. ' changed', why)
    end
end
print('PASS: an unknown continent, refused write, full table or changed layout waits and reports once; changed code disables')
