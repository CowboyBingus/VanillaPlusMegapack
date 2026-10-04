local source = assert(arg[1])
local resolve = assert(loadfile(source..'/resolve.lua'))()
local model = assert(loadfile(source..'/model.lua'))()
local function settings(weights)
    local ids = {1,2,3,5,7,6}
    local rows = {}
    for i,id in ipairs(ids) do rows[i] = {id=id,weight=weights[i],only_when_empty=false} end
    return {draws=1,candidates=rows,blockers={},fallback=0}
end
local low = settings({1,0.5,1,0.7,0.7,1})
local high = settings({1,0.8,1,0.2,0.5,1})
-- Settings are replaced below by recorded values generated from each native
-- capture. The comparisons exercise unsigned RNG output and float32 rounding.
local fixture = assert(loadfile(source..'/../tests/fixtures/seeds.lua'))()
for _, row in ipairs(fixture) do
    local got = resolve.base(row.seed,row.settings,row.initial)
    assert(table.concat(got,',') == table.concat(row.expected,','), 'Recorded seed mismatch: '..row.seed)
end
local fallback = {draws=1,candidates={},blockers={26,27,28,29,0},fallback=27}
assert(resolve.base(3,fallback,{})[1] == 27)
assert(table.concat(resolve.base(3,fallback,{26}),',') == '26')
local filtered = resolve.filter({1,11,9},1,{[9]=true})
assert(#filtered == 1 and filtered[1] == 11)
assert(not pcall(resolve.base,1,{draws=17,candidates={},blockers={},fallback=0},{}))
local T = assert(loadfile(source..'/bingus_text.lua'))()
T.registry().game_language = 'en'
local tr = T.new(assert(loadfile(source..'/../locales/en.lua'))())
for id = 1, 31 do
    assert(model.TITLES[id], 'Missing title for tag '..id)
    T.display(tr(model.TITLES[id]))
end
-- Subfactions, strains and operation modifiers lead; the base constellation follows.
assert(model.headline({1,11},tr) == 'DRAGONROACH ACTIVITY // BILE BUGS')
assert(model.headline({15,22},tr) == 'INCINERATION CORPS // ARTILLERY FORCES')
assert(model.headline({27},tr) == 'INVASION FLEET')
assert(model.headline({},tr) == 'STANDARD FORCES')
-- Display text is any script (translations); control characters never are.
assert(T.display('bad'..string.char(226,128,148)) and T.display('semi;colon'))
assert(not pcall(T.display,'bad'..string.char(1)) and not pcall(T.display,'bad'..string.char(255)))
print('PASS: recorded seed predictions, fallback, exclusions, subfaction headlines and display text')
assert(resolve.from_native(0)==0 and resolve.from_native(1)==31)
for id=2,31 do assert(resolve.from_native(id)==id-1) end
assert(not pcall(resolve.from_native,32))
assert(table.concat(resolve.filter({1,11,9},{[1]=true,[11]=true},{}),',')=='9')

-- The draw keeps its 64-bit state as two 32-bit words in plain numbers. The
-- reference below is the replica it replaced, unchanged: the same generator
-- in uint64_t cdata arithmetic, with fresh lists on every call. Both run over
-- the recorded captures, the mission records of every memory fixture and
-- generated settings (draws 0-16, only-when-empty rows, zero and repeated
-- weights, blockers, fallbacks, initial tags), each with many seeds,
-- including both ends of the 32-bit range. Tags, order and errors must match,
-- and filling reused lists must give what fresh lists give.
local ffi = require('ffi')
local reference = {}
do
    local float = ffi.new('float[1]')
    local high_word = ffi.new('uint64_t',4294967296)
    local multiplier = ffi.new('uint64_t',0x5851F42D) * high_word + 0x4C957F2D
    local increment = ffi.new('uint64_t',0x14057B7E) * high_word + 0xF767814F
    local function f32(value)
        float[0] = value
        return tonumber(float[0])
    end
    reference.f32 = f32
    -- One generator step on a uint64_t state: the next state, its high word
    -- and its low word.
    function reference.step(state)
        state = state * multiplier + increment
        return state, tonumber(state / high_word), tonumber(state % high_word)
    end
    local function add(tags, tag)
        if not tag or tag == 0 then return end
        assert(tag >= 1 and tag <= 31, 'Unknown enemy tag')
        for _, value in ipairs(tags) do if value == tag then return end end
        assert(#tags < 16, 'Too many enemy tags')
        tags[#tags + 1] = tag
    end
    function reference.base(seed, settings, initial)
        local tags, candidates, total = {}, {}, 0
        for _, tag in ipairs(initial or {}) do add(tags, tag) end
        for _, row in ipairs(settings.candidates) do
            assert(row.weight >= 0 and row.weight < math.huge, 'Invalid constellation weight')
            if row.id ~= 0 and (not row.only_when_empty or #tags == 0) then
                candidates[#candidates + 1] = row
                total = f32(total + row.weight)
            end
        end
        assert(settings.draws >= 0 and settings.draws <= 16, 'Invalid draw count')
        local state = ffi.new('uint64_t', seed)
        for _ = 1, settings.draws do
            if #candidates == 0 or total <= 0 then break end
            state = state * multiplier + increment
            local upper = tonumber(state / high_word)
            local target = f32(f32(f32(upper) * 2^-32) * total)
            local cumulative = 0
            for _, row in ipairs(candidates) do
                cumulative = f32(cumulative + row.weight)
                if cumulative >= target then
                    add(tags, row.id)
                    break
                end
            end
        end
        local blocked = false
        for _, blocker in ipairs(settings.blockers) do
            if blocker == 0 then break end
            for _, tag in ipairs(tags) do if tag == blocker then blocked = true end end
        end
        if not blocked then add(tags, settings.fallback) end
        return tags
    end
    function reference.filter(tags, excluded, disabled)
        local result = {}
        for _, tag in ipairs(tags) do
            if not (type(excluded)=='table' and excluded[tag] or tag==excluded) and not disabled[tag] then
                add(result, tag)
            end
        end
        return result
    end
end

-- A deterministic 32-bit generator for the inputs (exact in doubles): a
-- seed, or 0 to n - 1 from its high bits.
local generator = 2463534242
local function random(n)
    local a = generator % 65536
    generator = (a * 1664525 + (generator - a) / 65536 * 1664525 % 65536 * 65536 + 1013904223) % 4294967296
    return n and math.floor(generator / 4294967296 * n) or generator
end
local function u32(b, at) return b:byte(at+1) + b:byte(at+2)*256 + b:byte(at+3)*65536 + b:byte(at+4)*16777216 end
local function float_at(b, at)
    local cell = ffi.new('float[1]')
    ffi.copy(cell, b:sub(at+1, at+4), 4)
    return tonumber(cell[0])
end

-- Each memory fixture's mission record, decoded as mission.lua decodes it.
local memory = assert(loadfile(source..'/../tests/fixtures/memory.lua'))()
local CANDIDATES, FALLBACKS = {[2]=276,[3]=372,[4]=468}, {[2]=564,[3]=600,[4]=636}
local function fixture_settings(kind)
    local mission = memory.mission(kind)
    local descriptor, record
    for _, block in ipairs(mission.blocks) do
        if block.address == 0x30000000 + 0x4168d0 then descriptor = block.bytes end
    end
    local faction, difficulty = descriptor:byte(9), descriptor:byte(10)
    local at = 0x10000000 + 0x328d2a0 + (difficulty - 1) * 816
    for _, block in ipairs(mission.blocks) do
        if block.address == at then record = block.bytes end
    end
    local start, last = CANDIDATES[faction], FALLBACKS[faction]
    local result = {draws=u32(record,272), fallback=resolve.from_native(u32(record,last+32)), candidates={}, blockers={}}
    for i = 0, 7 do
        local row = start + i * 12
        result.candidates[i+1] = {id=resolve.from_native(u32(record,row)), weight=float_at(record,row+4),
            only_when_empty=record:byte(row+9) ~= 0}
        result.blockers[i+1] = resolve.from_native(u32(record,last+i*4))
    end
    return {name='memory fixture '..kind, settings=result, initial={}, seed=u32(descriptor,0)}
end

-- Generated settings, as a mission record can hold them (now and then an
-- invalid weight or draw count, which both must refuse alike).
local WEIGHTS = {0, 1, 0.5, 0.25, 0.699999988079071, 0.3499999940395355, 1e-7, 3, 100}
local INVALID = {-1, math.huge, 0 / 0}
local function weight()
    if random(400) == 0 then return INVALID[random(#INVALID) + 1] end
    return random(4) == 0 and WEIGHTS[random(#WEIGHTS) + 1] or resolve.f32(random(1000000) / 250000)
end
local function generated(index)
    local candidates, blockers = {}, {}
    for i = 1, 8 do
        candidates[i] = {id=random(3) == 0 and 0 or random(31) + 1, weight=weight(), only_when_empty=random(4) == 0}
        blockers[i] = random(3) == 0 and 0 or random(31) + 1
    end
    local initial = {}
    for i = 1, random(4) do initial[i] = random(5) == 0 and 0 or random(31) + 1 end
    return {name='generated '..index, settings={draws=random(100) == 0 and 17 or random(17), candidates=candidates,
        blockers=blockers, fallback=random(4) == 0 and 0 or random(31) + 1}, initial=initial}
end

local function message(ok, value)
    if ok then return nil end
    return (tostring(value):gsub('^.-:%d+: ', ''))
end
local function joined(tags) return table.concat(tags, ',') end
local reused_base, reused_filter = {}, {}
local compared, raised, filled, several, longest = 0, 0, 0, 0, 0
local function compare(case, seed)
    local ok, want = pcall(reference.base, seed, case.settings, case.initial)
    local fresh_ok, fresh = pcall(resolve.base, seed, case.settings, case.initial)
    local reuse_ok, reuse = pcall(resolve.base, seed, case.settings, case.initial, reused_base)
    local label = case.name..' seed '..seed
    assert(ok == fresh_ok and ok == reuse_ok, label..': a different outcome')
    compared = compared + 1
    if not ok then
        assert(message(ok, want) == message(fresh_ok, fresh) and message(ok, want) == message(reuse_ok, reuse),
            label..': a different error: '..tostring(want)..' / '..tostring(fresh))
        raised = raised + 1
        return
    end
    assert(reuse == reused_base, label..': the list passed in is the list filled')
    assert(joined(want) == joined(fresh) and joined(want) == joined(reuse),
        label..': '..joined(want)..' expected, '..joined(fresh)..' drawn ('..joined(reuse)..' reused)')
    -- Exclusions: none, one tag, a set; disabled tags from the backend.
    local excluded = random(3) == 0 and {} or random(2) == 0 and want[random(#want + 1) + 1] or
        {[random(31) + 1]=true, [want[1] or 0]=random(2) == 0}
    local disabled = {[want[random(#want + 1) + 1] or 0]=true}
    local kept = reference.filter(want, excluded, disabled)
    assert(joined(kept) == joined(resolve.filter(want, excluded, disabled))
        and joined(kept) == joined(resolve.filter(want, excluded, disabled, reused_filter)),
        label..': the filter differs')
    filled = filled + #kept
    if #want >= 3 then several = several + 1 end
    longest = math.max(longest, #want)
end

local cases = {}
for _, row in ipairs(fixture) do
    cases[#cases + 1] = {name='recorded seed '..row.seed, settings=row.settings, initial=row.initial, seed=row.seed}
end
for _, kind in ipairs({'host', 'join', 'other'}) do cases[#cases + 1] = fixture_settings(kind) end
local EDGES = {0, 1, 2, 3, 65535, 65536, 2147483647, 2147483648, 4294901760, 4294967294, 4294967295}
for _, case in ipairs(cases) do
    for _, seed in ipairs(EDGES) do compare(case, seed) end
    compare(case, case.seed)
    for _ = 1, 6000 do compare(case, random()) end
end
local fixed = compared
for index = 1, 12000 do
    local case = generated(index)
    for _ = 1, 4 do compare(case, random()) end
    compare(case, EDGES[random(#EDGES) + 1])
end
assert(raised > 0 and raised < (compared - fixed) / 10 and filled > 0 and several > 10000 and longest >= 8,
    'The generated settings must reach the errors, several draws and the filter')
assert(not pcall(resolve.base, -1, cases[1].settings, {}) and not pcall(resolve.base, 4294967296, cases[1].settings, {})
    and not pcall(resolve.base, 1.5, cases[1].settings, {}), 'Seeds outside the 32-bit field are refused')
local into = {}
assert(not pcall(resolve.filter, into, {}, {}, into), 'A filter never fills its own input')

-- The generator word for word: 64 steps from each of 2000 seeds (both ends of
-- the 32-bit range among them), every state's high and low word against
-- uint64_t arithmetic. A wrong carry moves the high word by one, which the
-- draw's float32 rounding nearly always hides: the draws alone cannot show it.
local steps = 0
for i = 1, 2000 do
    local seed = EDGES[i] or random()
    local state, high, low = ffi.new('uint64_t', seed), 0, seed
    for _ = 1, 64 do
        local want_high, want_low
        state, want_high, want_low = reference.step(state)
        high, low = resolve.step(high, low)
        assert(high == want_high and low == want_low, 'Generator state differs, seed '..seed)
        steps = steps + 1
    end
end

-- Draws on the float32 boundary. The weights total 3, so the target is
-- t = f32(u * 3) for the draw's u; the first row's running weight is t (it is
-- drawn), one float32 step below t (it is not), or reaches t only through the
-- float32 rounding of the running sum (it is drawn). Every rounding step of
-- the draw decides one of them; the replica must give the expected row and
-- the draw what the replica gives.
local boundaries = 0
local function boundary(seed, rows, expect)
    local settings = {draws=1, candidates={}, blockers={}, fallback=0}
    for k, row in ipairs(rows) do settings.candidates[k] = {id=row[1], weight=row[2], only_when_empty=false} end
    local want, got = reference.base(seed, settings, {}), resolve.base(seed, settings, {})
    assert(#want == 1 and want[1] == expect, 'Boundary case built wrongly, seed '..seed)
    assert(#got == 1 and got[1] == expect, 'Boundary draw differs, seed '..seed)
    boundaries = boundaries + 1
end
for _ = 1, 4000 do
    local seed = random()
    local _, upper = reference.step(ffi.new('uint64_t', seed))
    local u = reference.f32(reference.f32(upper) * 2^-32)
    if u >= 0.5 then
        local t = reference.f32(u * 3)
        local gap = t > 2 and 2^-22 or 2^-23
        boundary(seed, {{1, t}, {3, 3 - t}}, 1)
        boundary(seed, {{1, t - gap}, {3, 3 - (t - gap)}}, 3)
        boundary(seed, {{1, t - gap}, {2, 0.75 * gap}, {3, 3 - t}}, 2)
    end
end
assert(boundaries > 4000, 'Too few boundary draws')
print(string.format('PASS: allocation-free draw identical to the uint64 replica: %d draws over %d recorded and '
    ..'memory-fixture missions, %d over generated settings (%d raising the same error), %d on float32 boundaries; '
    ..'%d generator states word for word; filters identical, reused lists too',
    fixed, #cases, compared - fixed, raised, boundaries, steps))
