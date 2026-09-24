local ffi = require('ffi')
local bit = require('bit')
local M = {}
local float = ffi.new('float[1]')
local high_word = ffi.new('uint64_t',4294967296)
local multiplier = ffi.new('uint64_t',0x5851F42D) * high_word + 0x4C957F2D
local increment = ffi.new('uint64_t',0x14057B7E) * high_word + 0xF767814F

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

function M.base(seed, settings, initial)
    local tags, candidates, total = {}, {}, 0
    for _, tag in ipairs(initial or {}) do M.add(tags, tag) end
    for _, row in ipairs(settings.candidates) do
        assert(row.weight >= 0 and row.weight < math.huge, 'Invalid constellation weight')
        if row.id ~= 0 and (not row.only_when_empty or #tags == 0) then
            candidates[#candidates + 1] = row
            total = M.f32(total + row.weight)
        end
    end
    assert(settings.draws >= 0 and settings.draws <= 16, 'Invalid draw count')
    local state = ffi.new('uint64_t', seed)
    for _ = 1, settings.draws do
        if #candidates == 0 or total <= 0 then break end
        state = state * multiplier + increment
        local upper = tonumber(state / high_word)
        local target = M.f32(M.f32(M.f32(upper) * 2^-32) * total)
        local cumulative = 0
        for _, row in ipairs(candidates) do
            cumulative = M.f32(cumulative + row.weight)
            if cumulative >= target then
                M.add(tags, row.id)
                break
            end
        end
    end
    local blocked = false
    for _, blocker in ipairs(settings.blockers) do
        if blocker == 0 then break end
        for _, tag in ipairs(tags) do if tag == blocker then blocked = true end end
    end
    if not blocked then M.add(tags, settings.fallback) end
    return tags
end

local function mul32(a, b)
    return tonumber(ffi.cast('uint32_t', ffi.new('uint64_t', a) * ffi.new('uint64_t', b)))
end

function M.exclusion_key(hash)
    local value = 3781555287
    for _, word in ipairs({3964548889, hash}) do
        local mixed = mul32(word, 1540483477)
        mixed = mul32(bit.bxor(mixed, bit.rshift(mixed, 24)) % 4294967296, 1540483477)
        value = bit.bxor(mixed, mul32(value, 1540483477)) % 4294967296
    end
    return value
end

-- Keep authored catalogue IDs stable after native tag 1 was inserted in build 25480438.
function M.from_native(tag)
    assert(tag >= 0 and tag <= 31, 'Unknown native enemy tag')
    if tag == 1 then return 31 end
    return tag > 1 and tag - 1 or 0
end

function M.filter(tags, excluded, disabled)
    local result = {}
    for _, tag in ipairs(tags) do
        if not (type(excluded)=='table' and excluded[tag] or tag==excluded) and not disabled[tag] then M.add(result, tag) end
    end
    return result
end

return M
