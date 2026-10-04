local patch = {
    buffer_rva = 0x348e8f8,
    table_rva = 0x37cb600,
    data_size = 80280,
    groups = 11,
    record_size = 400,
    flag_offset = 0x170,
    -- The one bit of a record's navigation flags this mod owns
    -- (deploy_on_navmesh_only): cleared in the records whose supported-build
    -- flags below set it. The other bits belong to the game and other mods.
    owned_bit = 0x02,
    owned_records = 103,
    vanilla_flags = {
        2, 2, 0, 0, 2, 2, 0, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 0, 2, 3, 0,
        2, 2, 2, 2, 2, 0, 0, 2, 0, 2, 2, 2, 0, 1, 2, 1, 0, 2, 1, 0, 2,
        2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 0, 2,
        2, 0, 2, 2, 2, 3, 2, 0, 0, 2, 0, 2, 2, 2, 2, 2, 2, 2, 3, 0, 2,
        3, 2, 2, 0, 2, 3, 0, 2, 1, 0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2,
        0, 0, 2, 3, 2, 0, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 0, 0, 0, 0,
        2, 0, 2, 2, 2, 0, 0, 2, 2, 0, 2, 0, 2, 0, 2, 2, 3, 2, 0, 0, 2,
        0, 2
    }
}
local OWNED, OTHERS = patch.owned_bit, bit.band(bit.bnot(patch.owned_bit), 0xFF)

local function u32(bytes, offset)
    assert(offset >= 0 and offset + 4 <= #bytes, 'Settings field out of bounds')
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- The settings bytes with every planned change applied (changes sorted by offset),
-- built once. Rebuilding the 80 KB buffer per changed byte made about 16 MB of
-- short-lived strings in one frame; this makes one copy plus small pieces.
local function with_changes(source, changes)
    local parts, last = {}, 0
    for _, change in ipairs(changes) do
        parts[#parts + 1] = source:sub(last + 1, change[1])
        parts[#parts + 1] = change[2]
        last = change[1] + 1
    end
    parts[#parts + 1] = source:sub(last + 1)
    return table.concat(parts)
end

-- One record: its identity is checked, and only this mod's bit decides whether
-- it is written. Other bits may hold another mod's changes, and a bit that is
-- already clear (this mod's target state) is accepted and never written.
local function plan_record(api, plan, record)
    local kind = u32(plan.source, record)
    assert(patch.vanilla_flags[kind] and not plan.seen[kind], 'Unexpected or duplicate stratagem')
    assert(api.pointer(plan.table_bytes, kind * 8) == plan.buffer + record, 'Settings table identity mismatch')
    plan.seen[kind], plan.records = true, plan.records + 1
    if bit.band(patch.vanilla_flags[kind], OWNED) == 0 then return end
    plan.owned = plan.owned + 1
    local position = record + patch.flag_offset
    local flags = plan.source:byte(position + 1)
    if bit.band(flags, OWNED) == 0 then
        plan.already = plan.already + 1
        return
    end
    -- [1] and [2] are the offset and bytes write_batch takes.
    plan.changes[#plan.changes + 1] = {position, string.char(bit.band(flags, OTHERS)), record = record, kind = kind}
end

local function plan_group(api, plan, root, finish)
    local count = u32(plan.source, root + 8)
    assert(count > 0 and count <= #patch.vanilla_flags, 'Invalid record count')
    local items = assert(api.pointer(plan.source, root), 'Settings items unavailable')
    local start = api.distance(items, plan.buffer)
    assert(start >= root + 16 and start + count * patch.record_size <= finish, 'Settings records out of bounds')
    for index = 0, count - 1 do
        plan_record(api, plan, start + index * patch.record_size)
    end
end

local function prepare(api, module)
    assert(module, 'Game module unavailable')
    local pointer_bytes = api.read(module + patch.buffer_rva, 8)
    local buffer = assert(api.pointer(pointer_bytes), 'Settings buffer unavailable')
    local source = assert(api.read(buffer, patch.data_size), 'Cannot read settings')
    local table_bytes = assert(api.read(module + patch.table_rva, 150 * 8), 'Cannot read settings table')
    assert(u32(source, 0) == patch.groups, 'Unexpected settings group count')
    local plan = {buffer = buffer, source = source, pointer_bytes = pointer_bytes, table_bytes = table_bytes,
        seen = {}, records = 0, owned = 0, already = 0, changes = {}, landed = 0}
    local offset = 4
    for _ = 1, patch.groups do
        assert(u32(source, offset) == 0x444C444C and u32(source, offset + 4) == 1
            and u32(source, offset + 8) == 0x30EB6399
            and u32(source, offset + 16) == 1 and u32(source, offset + 20) == 0, 'Unexpected settings header')
        local root = offset + 24
        local finish = root + u32(source, offset + 12)
        assert(finish >= root + 16 and finish <= #source, 'Settings group out of bounds')
        plan_group(api, plan, root, finish)
        offset = finish
    end
    assert(offset == #source and plan.records == 149 and plan.owned == patch.owned_records,
        'Incomplete stratagem settings')
    table.sort(plan.changes, function(a, b) return a[1] < b[1] end)
    plan.seen, plan.table_bytes = nil, nil
    return plan
end

local function write(api, module, plan)
    assert(api.read(module + patch.buffer_rva, 8) == plan.pointer_bytes, 'Settings buffer changed')
    assert(api.read(plan.buffer, patch.data_size) == plan.source, 'Settings changed during validation')
    -- One protection query for the whole settings buffer, right before the
    -- writes: only committed private read-write memory is written.
    local written, landed = api.write_batch(plan.buffer, patch.data_size, plan.changes)
    plan.landed = landed
    assert(written, 'Settings write refused or failed after ' .. landed .. ' of ' .. #plan.changes .. ' flags')
    assert(api.read(plan.buffer, patch.data_size) == with_changes(plan.source, plan.changes),
        'Settings verification failed')
end

-- Sets this mod's bit again in the first `count` records it cleared (default:
-- all of them) where the bit is still clear and the record is still the same
-- stratagem. Every other bit keeps its current value, and a bit another mod has
-- set again is left alone. One read and, when there is something to put back,
-- one protection query. True when none of this mod's changes remain.
function patch.restore(api, module, plan, count)
    count = count or #plan.changes
    if count == 0 then return true end
    if api.read(module + patch.buffer_rva, 8) ~= plan.pointer_bytes then return false end
    local current = api.read(plan.buffer, patch.data_size)
    if not current then return false end
    local undo, intact = {}, true
    for index = 1, count do
        local change = plan.changes[index]
        local flags = current:byte(change[1] + 1)
        if u32(current, change.record) ~= change.kind then
            intact = false
        elseif bit.band(flags, OWNED) == 0 then
            undo[#undo + 1] = {change[1], string.char(bit.bor(flags, OWNED))}
        end
    end
    if #undo == 0 then return intact end
    return api.write_batch(plan.buffer, patch.data_size, undo) and intact
end

local function ready(plan)
    local text = 'navigation_settings_ready: ' .. patch.owned_records .. ' flags'
    if plan.already > 0 then text = text .. ' (' .. plan.already .. ' already clear)' end
    return text .. '; executable code unchanged'
end

-- true, status and the applied changes (for patch.restore), or false and why.
-- Nothing is written when every owned bit is already clear.
function patch.apply(api, module)
    local valid, plan = pcall(prepare, api, module)
    if not valid then return false, tostring(plan) end
    if #plan.changes > 0 then
        local ok, reason = pcall(write, api, module, plan)
        if not ok then
            local restored = patch.restore(api, module, plan, plan.landed)
            return false, tostring(reason) .. '; partial-edit recovery=' .. tostring(restored)
        end
    end
    plan.source = nil
    return true, ready(plan), plan
end

return patch
