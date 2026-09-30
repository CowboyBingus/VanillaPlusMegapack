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
