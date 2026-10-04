-- The constellation draw and the tag rules, as the game resolves them. Runs on
-- the 0.5 s refresh only, interpreted, and allocates nothing when the caller
-- passes the lists to fill.
local ffi = require('ffi')
local bit = require('bit')
local M = {}
local float = ffi.new('float[1]')
local NONE = {}
local WORD = 4294967296
-- The native draw is a 64-bit linear congruential generator: state = state *
-- multiplier + increment (mod 2^64), and each draw uses the state's high 32
-- bits. The state is kept as its two 32-bit words in plain numbers, every
-- partial product exact in a double, so a draw creates no 64-bit cdata.
local MULTIPLIER_HIGH, MULTIPLIER_LOW = 0x5851F42D, 0x4C957F2D
local INCREMENT_HIGH, INCREMENT_LOW = 0x14057B7E, 0xF767814F

function M.f32(value)
    float[0] = value
    return tonumber(float[0])
end

function M.add(tags, tag)
    if not tag or tag == 0 then return end
    assert(tag >= 1 and tag <= 31, 'Unknown enemy tag')
    for _, value in ipairs(tags) do if value == tag then return end end
    assert(#tags < 16, 'Too many enemy tags')
    tags[#tags + 1] = tag
end

-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles (no 64-bit cdata).
local function mul32(a, b)
    local low = a % 65536
    return (low * b + (a - low) / 65536 * b % 65536 * 65536) % 4294967296
end

-- a * b for 32-bit a and b, as its high and low 32-bit words: 16-bit partial
-- products, each exact in a double.
local function mul64(a, b)
    local a0, b0 = a % 65536, b % 65536
    local a1, b1 = (a - a0) / 65536, (b - b0) / 65536
    local middle = a1 * b0 + a0 * b1
    local low = a0 * b0 + middle % 65536 * 65536
    local carry = low >= WORD and 1 or 0
    return a1 * b1 + (middle - middle % 65536) / 65536 + carry, low - carry * WORD
end

-- The generator's next state from (high, low): its high and low words.
-- Public so the tests can check every state against uint64_t arithmetic.
local function step(high, low)
    local product_high, product_low = mul64(low, MULTIPLIER_LOW)
    local sum_low = product_low + INCREMENT_LOW
    local carry = sum_low >= WORD and 1 or 0
    local sum_high = product_high + mul32(high, MULTIPLIER_LOW) + mul32(low, MULTIPLIER_HIGH) + INCREMENT_HIGH + carry
    return sum_high % WORD, sum_low - carry * WORD
end
M.step = step

-- The list, emptied.
local function emptied(list)
    for i = #list, 1, -1 do list[i] = nil end
    return list
end

-- A candidate row takes part in the draw when it names a tag and, if it is
-- only for missions without tags, no tag came before the draws.
local function drawable(row, empty)
    return row.id ~= 0 and (not row.only_when_empty or empty)
end

-- The drawable rows' count and their float32 weight total. Every row's
-- weight is checked, drawable or not.
local function weights(candidates, empty)
    local count, total = 0, 0
    for _, row in ipairs(candidates) do
        assert(row.weight >= 0 and row.weight < math.huge, 'Invalid constellation weight')
        if drawable(row, empty) then
            count, total = count + 1, M.f32(total + row.weight)
        end
    end
    return count, total
end

-- The tag of the first drawable row whose float32 running weight reaches
-- target, or nil.
local function pick(candidates, empty, target)
    local cumulative = 0
    for _, row in ipairs(candidates) do
        if drawable(row, empty) then
            cumulative = M.f32(cumulative + row.weight)
            if cumulative >= target then return row.id end
        end
    end
    return nil
end

-- Whether one of the blockers before the first 0 is among the tags.
local function blocked(tags, blockers)
    for _, blocker in ipairs(blockers) do
        if blocker == 0 then return false end
        for _, tag in ipairs(tags) do
            if tag == blocker then return true end
        end
    end
    return false
end

-- The tags a mission's 32-bit seed draws: the initial tags, `settings.draws`
-- weighted draws among the candidates, then the fallback unless a blocker is
-- among them. Fills `into` (emptied first; a new table when none is given).
function M.base(seed, settings, initial, into)
    local tags = emptied(into or {})
    for _, tag in ipairs(initial or NONE) do M.add(tags, tag) end
    local candidates, empty = settings.candidates, #tags == 0
    local count, total = weights(candidates, empty)
    assert(settings.draws >= 0 and settings.draws <= 16, 'Invalid draw count')
    assert(seed >= 0 and seed < WORD and seed % 1 == 0, 'Invalid mission seed')
    local high, low = 0, seed
    for _ = 1, settings.draws do
        if count == 0 or total <= 0 then break end
        high, low = step(high, low)
        M.add(tags, pick(candidates, empty, M.f32(M.f32(M.f32(high) * 2^-32) * total)))
    end
    if not blocked(tags, settings.blockers) then M.add(tags, settings.fallback) end
    return tags
end

local function mix(value, word)
    local mixed = mul32(word, 1540483477)
    mixed = mul32(bit.bxor(mixed, bit.rshift(mixed, 24)) % 4294967296, 1540483477)
    return bit.bxor(mixed, mul32(value, 1540483477)) % 4294967296
end

function M.exclusion_key(hash)
    local value = mix(3781555287, 3964548889)
    -- Without a hash only the fixed word is mixed in (as an ipairs over both stopped).
    if hash == nil then return value end
    return mix(value, hash)
end

-- Keep authored catalogue IDs stable after native tag 1 was inserted in build 25480438.
function M.from_native(tag)
    assert(tag >= 0 and tag <= 31, 'Unknown native enemy tag')
    if tag == 1 then return 31 end
    return tag > 1 and tag - 1 or 0
end

-- The tags neither excluded (one tag, or a set) nor disabled, in order. Fills
-- `into` (emptied first; a new table when none is given; never `tags`).
function M.filter(tags, excluded, disabled, into)
    assert(into == nil or into ~= tags, 'Filter into its own input')
    local result = emptied(into or {})
    for _, tag in ipairs(tags) do
        if not (type(excluded)=='table' and excluded[tag] or tag==excluded) and not disabled[tag] then M.add(result, tag) end
    end
    return result
end

-- Every function here runs only on the 0.5 s refresh: kept interpreted, they
-- add no traces to the game's shared LuaJIT code cache.
if jit and jit.off then
    for _, fn in ipairs({M.f32, M.add, mul32, mul64, step, emptied, drawable, weights, pick, blocked, M.base, mix,
                         M.exclusion_key, M.from_native, M.filter}) do
        jit.off(fn)
    end
end

return M
