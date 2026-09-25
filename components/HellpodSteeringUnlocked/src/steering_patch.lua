-- Ownership and layout checks keep the write confined to the base avoidance flag.
local ffi
local patch = {
    manager_rva = 0x346d578, owner_rva = 0x347cf18,
    owner_offset = 0x7c8c90, size = 69688,
}
local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function number(bytes, offset)
    ffi = ffi or require('ffi')
    local value = ffi.new('float[1]')
    ffi.copy(value, bytes:sub(offset + 1, offset + 4), 4)
    return tonumber(value[0])
end
local function near(a, b)
    return a == a and math.abs(a - b) <= math.max(0.00001, math.abs(b) * 0.00001)
end

function patch.apply(api, game)
    local manager = api.pointer(api.read(game + patch.manager_rva, 8))
    local owner = api.pointer(api.read(game + patch.owner_rva, 8))
    if not manager or not owner then return true, 'waiting_for_mission', false end
    if api.distance(manager, owner) ~= patch.owner_offset then
        return false, 'avoidance_owner_mismatch', false
    end
    local enabled = api.read(manager, 1)
    local records = api.read(manager + 32772, 4)
    local links = api.read(manager + 65544, 4)
    local set = api.read(manager + 65552, 24)
    local dimensions = api.read(manager + 69672, 16)
    if not (enabled and records and links and set and dimensions) then
        return false, 'avoidance_fields_unreadable', false
    end
    -- Aboard ship this storage exists but has not been initialized.
    if enabled == '\0' and records == string.rep('\0', 4) and links == records
        and set == string.rep('\0', 24) and dimensions == string.rep('\0', 16) then
        return true, 'waiting_for_mission', false
    end
    local slots = api.pointer(set)
    local width, half, cell, reciprocal = number(dimensions, 0), number(dimensions, 4),
                                          number(dimensions, 8), number(dimensions, 12)
    if (enabled ~= '\0' and enabled ~= '\1') or u32(records, 0) > 1024
        or u32(links, 0) > 8192 or not slots or api.distance(slots, manager) ~= 65576
        or u32(set, 8) ~= 1024 or u32(set, 12) > 1024 or u32(set, 16) ~= 3
        or not (width >= 64 and width <= 16384)
        or not near(half, width / 2) or not near(cell, width / 64)
        or not near(reciprocal, 1 / cell) then
        return false, 'avoidance_layout_mismatch', false
    end
    if enabled == '\0' then return true, 'avoidance_settings_ready', true end
    -- Checked only before a write: once settings are ready, every 10 Hz poll
    -- used to repeat this memory-protection query for nothing.
    if not api.writable_data(manager, patch.size) then
        return false, 'avoidance_is_not_writable_private_data', false
    end
    -- Recheck identity and the exact target immediately before the single-byte
    -- write. Mission initialization can reset this manager between checks.
    local current = api.pointer(api.read(game + patch.manager_rva, 8))
    local current_owner = api.pointer(api.read(game + patch.owner_rva, 8))
    if not current or not current_owner or api.distance(current, manager) ~= 0
        or api.distance(current_owner, owner) ~= 0 or api.read(manager, 1) ~= '\1'
        or api.read(manager + 65552, 24) ~= set
        or api.read(manager + 69672, 16) ~= dimensions then
        return true, 'waiting_for_stable_mission', false
    end
    if not api.write(manager, '\0') or api.read(manager, 1) ~= '\0' then
        return false, 'avoidance_data_write_failed', false
    end
    return true, 'avoidance_settings_ready', true
end
return patch
