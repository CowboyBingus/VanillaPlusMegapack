-- Eligible enemies and spawn-rate levels for one mission, from roster_data.lua.
-- Mirrors native build 25480438: group builder 0x94be10, group weight
-- 0x94a0a0 with the war-effect clamp 0x12e3c00, tag predicate 0x177e3c0 and
-- replacement chain 0x949b80. Runs once per mission key, never per frame.
local M = {}

local PATROL, GARRISON, REINFORCEMENT, TRAVEL, AIR = 2, 4, 5, 6, 9
-- Air support fires every 300-600 s against 65-200 s patrol timers.
local AIR_RATE = 0.25
-- A unit at 16% of all spawns fills the meter; each halving removes 1.5 ticks.
local FULL, STEP, TICKS = 0.16, 1.5, 10
local PLACEHOLDER = 0.1

local function any(tags, list)
    for i = 1, #list do
        if tags[list[i]] then return true end
    end
    return false
end

local function accepts(tags, required, excluded)
    for i = 1, #excluded do
        if tags[excluded[i]] then return false end
    end
    return #required == 0 or any(tags, required)
end

-- Highest-priority matching rule wins; a later step may not lower the priority.
local function replace(faction, resource, tags, difficulty)
    local priority = -1
    for _ = 1, 5 do
        local best
        for _, rule in ipairs(faction.swaps) do
            if rule[2] == resource and tags[rule[1]] and difficulty >= rule[4] and difficulty <= rule[5]
                and (not best or rule[6] > best[6]) then
                best = rule
            end
        end
        if not best or best[6] < priority then break end
        resource, priority = best[3], best[6]
    end
    return resource
end

-- Eligible unit rows of one family with their displayed name and weight share.
local function members_of(context, family)
    local cached = context.families[family]
    if cached then return cached end
    local faction, tags, difficulty = context.faction, context.tags, context.difficulty
    local list, total = {}, 0
    for _, unit in ipairs(faction.units) do
        local weight = unit[1] == family and unit[3][difficulty] or 0
        if weight > 0 and accepts(tags, unit[4], unit[5]) then
            list[#list + 1] = {faction.resources[replace(faction, unit[2], tags, difficulty)], weight}
            total = total + weight
        end
    end
    for _, entry in ipairs(list) do entry[3] = entry[2] / total end
    context.families[family] = list
    return list
end

local function clamp(value)
    if value < 0 then return 0 end
    if value > 10000 then return 10000 end
    return value
end

local function weight_of(context, group)
    local weight = group[4][context.difficulty] or group[3]
    local zone, war, families = context.zone, context.war, context.faction.families
    if zone or war then
        local product = 1
        if zone then
            for _, member in ipairs(group[10]) do product = product * (zone[families[member[1]]] or 1) end
        end
        for _, member in ipairs(group[10]) do
            if war then product = product * (war[families[member[1]]] or 1) end
            product = clamp(product)
        end
        weight = weight * clamp(product)
    end
    if group[1] == 8 and weight < 0.1 then weight = 0.1 end
    return weight
end

-- Groups the native builder keeps for one pool, as {weight, group}.
local function eligible(context, pool, category)
    local result = {}
    for _, group in ipairs(context.faction.groups) do
        local difficulty = context.difficulty
        if group[1] == pool and (not category or group[2] == category)
            and difficulty >= group[5] and difficulty <= group[6] and group[7] <= 4 and group[8] >= 1
            and (#group[9] == 0 or any(context.tags, group[9])) then
            local weight = weight_of(context, group)
            local complete = weight > 0
            for _, member in ipairs(group[10]) do
                if complete and #members_of(context, member[1]) == 0 then complete = false end
            end
            if complete then result[#result + 1] = {weight, group} end
        end
    end
    return result
end

-- Expected units of each name per weighted draw from a list of groups.
local function draws(context, groups, counts, rate)
    local total = 0
    for _, item in ipairs(groups) do total = total + item[1] end
    for _, item in ipairs(groups) do
        for _, member in ipairs(item[2][10]) do
            local count = member[2] >= 999 and 1 or member[2]
            for _, entry in ipairs(members_of(context, member[1])) do
                if entry[1] > 0 then
                    counts[entry[1]] = (counts[entry[1]] or 0) + rate * item[1] / total * count * entry[3]
                end
            end
        end
    end
end

local function shares(counts)
    local total = 0
    for _, value in pairs(counts) do total = total + value end
    if total <= 0 then return nil end
    local result = {}
    for name, value in pairs(counts) do result[name] = value / total end
    return result
end

-- Patrols: one equal-rate stream per patrol category, plus gated border
-- travelers at the same rate and Illuminate air support at a quarter.
local function patrols(context)
    local counts = {}
    for category = 1, 4 do
        local groups = eligible(context, PATROL, category)
        if #groups > 0 then draws(context, groups, counts, 1) end
    end
    if context.travel then
        local groups = eligible(context, TRAVEL)
        if #groups > 0 then draws(context, groups, counts, 1) end
    end
    local air = eligible(context, AIR)
    if #air > 0 then draws(context, air, counts, AIR_RATE) end
    return shares(counts)
end

-- Garrisons pick a member family by its summed unit weight, then a unit by weight.
-- Groups at a placeholder weight (build 25480438 raised two from 0 to 0.01)
-- are treated as disabled: garrison spawn points also filter by unit masks
-- that are not modelled, and the wiki does not report those units there.
local function garrisons(context)
    local counts = {}
    for _, item in ipairs(eligible(context, GARRISON)) do
        for _, member in ipairs(item[1] >= PLACEHOLDER and item[2][10] or {}) do
            for _, entry in ipairs(members_of(context, member[1])) do
                if entry[1] > 0 then counts[entry[1]] = (counts[entry[1]] or 0) + entry[2] end
            end
        end
    end
    return shares(counts)
end

local function reinforcements(context)
    local counts = {}
    local groups = eligible(context, REINFORCEMENT)
    if #groups > 0 then draws(context, groups, counts, 1) end
    return shares(counts)
end

function M.ticks(share)
    if not share or share <= 0 then return 0 end
    local value = math.floor(TICKS + STEP * math.log(share / FULL) / math.log(2) + 0.5)
    if value < 1 then return 1 end
    if value > TICKS then return TICKS end
    return value
end

local function order(data, share)
    return function(a, b)
        local x, y = share[a] or 0, share[b] or 0
        if x ~= y then return x > y end
        return data.names[a][1] < data.names[b][1]
    end
end

-- Returns {large = {{name, ticks}, ...}, small = {name, ...}} using names indexes.
function M.compute(data, snapshot, zone, war)
    local faction = assert(data.factions[snapshot.faction], 'Unknown faction')
    local difficulty = snapshot.difficulty
    assert(difficulty >= 1 and difficulty <= 10, 'Invalid difficulty')
    local tags = {}
    for _, tag in ipairs(snapshot.tags) do tags[tag] = true end
    local context = {faction=faction, tags=tags, difficulty=difficulty, families={},
        zone=zone and next(zone) and zone or nil, war=war and next(war) and war or nil,
        travel=any(tags, faction.travel)}
    local share, sources = {}, 0
    for _, source in pairs({patrols(context), reinforcements(context), garrisons(context)}) do
        -- Empty sources are nil, so pairs rather than ipairs visits every other one.
        sources = sources + 1
        for name, value in pairs(source) do share[name] = (share[name] or 0) + value end
    end
    local listed = {}
    for name, value in pairs(share) do
        share[name] = value / sources
        if not data.hidden[name] then listed[#listed + 1] = name end
    end
    local extra = {}
    if faction.summoned then
        local commanded = false
        for name in pairs(data.commanders) do commanded = commanded or (share[name] or 0) > 0 end
        if commanded then
            for _, entry in ipairs(members_of(context, faction.summoned)) do
                if entry[1] > 0 and not share[entry[1]] then extra[entry[1]] = true end
            end
        end
    end
    local hive = data.hive_lord
    if tags[hive.tag] and difficulty >= hive.difficulty and not share[hive.name] then extra[hive.name] = true end
    for name in pairs(extra) do listed[#listed + 1] = name end
    table.sort(listed, order(data, share))
    local report = {large={}, small={}}
    for _, name in ipairs(listed) do
        if data.names[name][2] >= 3 then
            report.large[#report.large + 1] = {name, math.max(1, M.ticks(share[name]))}
        else
            report.small[#report.small + 1] = name
        end
    end
    return report
end

-- One-entry cache: the forecast only changes when the mission inputs do.
function M.new(data)
    local self = {computed=0}
    function self:report(snapshot, zone, war)
        local parts = {snapshot.faction, snapshot.difficulty}
        local sorted = {}
        for _, tag in ipairs(snapshot.tags) do sorted[#sorted + 1] = tag end
        table.sort(sorted)
        parts[#parts + 1] = table.concat(sorted, ',')
        for _, map in ipairs({zone or {}, war or {}}) do
            local keys = {}
            for family, value in pairs(map) do keys[#keys + 1] = family .. '=' .. value end
            table.sort(keys)
            parts[#parts + 1] = table.concat(keys, ',')
        end
        local key = table.concat(parts, '|')
        if key ~= self.key then
            self.value = M.compute(data, snapshot, zone, war)
            self.key = key
            self.computed = self.computed + 1
        end
        return self.value, self.key
    end
    return self
end

-- Keep this rarely run code interpreted: it must not add traces to the
-- game's shared LuaJIT code cache.
if jit and jit.off then
    for _, fn in ipairs({any, accepts, replace, members_of, clamp, weight_of, eligible, draws, shares,
                         patrols, garrisons, reinforcements, order, M.ticks, M.compute, M.new}) do
        jit.off(fn, true)
    end
end

return M
