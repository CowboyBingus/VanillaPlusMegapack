-- Ownership and layout checks keep the write confined to the base avoidance flag.
local ffi = require('ffi')
local patch = {
    manager_rva = 0x346d578, owner_rva = 0x347cf18,
    owner_offset = 0x7c8c90, size = 69688,
}
-- The flag's values. Mission initialization sets the game's own value, 1; it is
-- the only value this mod ever replaces, with its own value, 0. Any other value
-- in an otherwise valid manager was written by someone else and is left alone.
local GAME_VALUE, OWN_VALUE = 1, 0
local HIGH = 4294967296

-- Every read lands in one of these buffers, made once, and is decoded in place
-- into numbers: a check allocates nothing (no string, pointer or 64-bit cdata).
-- The addresses it reads are cdata made once per game module and once per
-- manager address (slots and fields below).
local words = ffi.new('uint32_t[6]')  -- a pointer (words 0-1), or the 24-byte set
local word = ffi.new('uint32_t[1]')   -- a record or link count
local flag = ffi.new('uint8_t[1]')    -- the enable byte
local dims = ffi.new('float[4]')      -- width, half width, cell, reciprocal

local slots_game, manager_slot, owner_slot
local function slots(game)
    if game ~= slots_game then
        slots_game, manager_slot, owner_slot = game, game + patch.manager_rva, game + patch.owner_rva
    end
    return manager_slot, owner_slot
end
local fields_manager, at_flag, at_records, at_links, at_set, at_dims
local function fields(manager)
    if manager ~= fields_manager then
        local base = ffi.cast('uint8_t *', manager)
        fields_manager, at_flag, at_records, at_links = manager, base, base + 32772, base + 65544
        at_set, at_dims = base + 65552, base + 69672
    end
end

-- The user-mode pointer stored at address, as a number; nil when unreadable,
-- null or out of range (the runtime's pointer rules).
local function pointer_at(api, address)
    if not api.read_into(address, 8, words) then return nil end
    local high = words[1]
    if high >= 0x8000 then return nil end
    local value = words[0] + high * HIGH
    if value < 0x10000 then return nil end
    return value
end
local function count_at(api, address)
    if not api.read_into(address, 4, word) then return nil end
    return word[0]
end

local function near(a, b)
    return a == a and math.abs(a - b) <= math.max(0.00001, math.abs(b) * 0.00001)
end
-- An exact +0.0: all four bytes zero.
local function zero(value)
    return value == 0 and 1 / value > 0
end
-- Aboard ship this storage exists but has not been initialized: every field zero.
local function blank(records, links)
    return flag[0] == 0 and records == 0 and links == 0
        and words[0] == 0 and words[1] == 0 and words[2] == 0 and words[3] == 0 and words[4] == 0 and words[5] == 0
        and zero(dims[0]) and zero(dims[1]) and zero(dims[2]) and zero(dims[3])
end
-- Record and link bounds, the set's self-pointer and the map geometry of an
-- initialized manager, from the buffers just read. The flag is classified apart
-- (see patch.apply).
local function layout_valid(manager, records, links)
    local width, half, cell, reciprocal = dims[0], dims[1], dims[2], dims[3]
    return records <= 1024 and links <= 8192
        and words[1] < 0x8000 and words[0] + words[1] * HIGH - manager == 65576
        and words[2] == 1024 and words[3] <= 1024 and words[4] == 3
        and width >= 64 and width <= 16384
        and near(half, width / 2) and near(cell, width / 64) and near(reciprocal, 1 / cell)
end

-- One reused view of the manager, so a poll allocates no table.
local view = {set = {0, 0, 0, 0, 0, 0}, dims = {0, 0, 0, 0}}
-- The manager as read now: the view when it is initialized and its layout is
-- valid, otherwise nil, whether to keep polling, and the status.
local function inspect(api, game)
    local manager_address, owner_address = slots(game)
    local manager, owner = pointer_at(api, manager_address), pointer_at(api, owner_address)
    if not manager or not owner then return nil, true, 'waiting_for_mission' end
    if manager - owner ~= patch.owner_offset then return nil, false, 'avoidance_owner_mismatch' end
    fields(manager)
    local read_flag = api.read_into(at_flag, 1, flag)
    local records, links = count_at(api, at_records), count_at(api, at_links)
    local read_set, read_dims = api.read_into(at_set, 24, words), api.read_into(at_dims, 16, dims)
    if not (read_flag and records and links and read_set and read_dims) then
        return nil, false, 'avoidance_fields_unreadable'
    end
    if blank(records, links) then return nil, true, 'waiting_for_mission' end
    if not layout_valid(manager, records, links) then return nil, false, 'avoidance_layout_mismatch' end
    view.manager, view.owner, view.enabled = manager, owner, flag[0]
    local set, dimensions = view.set, view.dims
    for i = 0, 5 do set[i + 1] = words[i] end
    for i = 0, 3 do dimensions[i + 1] = dims[i] end
    return view
end

-- This mod's own write: the manager and owner addresses, set and dimensions of
-- the manager it cleared, as numbers, so tracking costs no read or allocation.
local function remember(own, v)
    own.manager, own.owner = v.manager, v.owner
    own.set, own.dims = own.set or {}, own.dims or {}
    for i = 1, 6 do own.set[i] = v.set[i] end
    for i = 1, 4 do own.dims[i] = v.dims[i] end
end
local function forget(own)
    own.manager = nil
end
local function owns(own, v)
    if own.manager ~= v.manager or own.owner ~= v.owner then return false end
    for i = 1, 6 do if own.set[i] ~= v.set[i] then return false end end
    for i = 1, 4 do if own.dims[i] ~= v.dims[i] then return false end end
    return true
end

-- The set and the dimensions just read, against the view.
local function same_set(v)
    for i = 0, 5 do if words[i] ~= v.set[i + 1] then return false end end
    return true
end
local function same_dims(v)
    for i = 0, 3 do if dims[i] ~= v.dims[i + 1] then return false end end
    return true
end
-- Recheck identity and the exact target immediately before a write. Mission
-- initialization can reset this manager between checks.
local function stable(api, game, v, expected)
    local manager_address, owner_address = slots(game)
    local manager, owner = pointer_at(api, manager_address), pointer_at(api, owner_address)
    fields(v.manager)
    return manager == v.manager and owner == v.owner
        and api.read_into(at_flag, 1, flag) and flag[0] == expected
        and api.read_into(at_set, 24, words) and same_set(v)
        and api.read_into(at_dims, 16, dims) and same_dims(v)
end

-- The single write. One memory-protection query, right before the one-byte
-- store, requires the whole manager to be committed private read-write data
-- (never executable or module pages). Only a refused write queries again, to
-- report which check failed. Returns nothing on success, else the failure.
local CLEAR, RESTORE = {{0, '\0'}}, {{0, '\1'}}
local function write_flag(api, v, change, value)
    fields(v.manager)
    if not api.write_batch(at_flag, patch.size, change) then
        if not api.writable_data(at_flag, patch.size) then return 'avoidance_is_not_writable_private_data' end
        return 'avoidance_data_write_failed'
    end
    if not api.read_into(at_flag, 1, flag) or flag[0] ~= value then return 'avoidance_data_write_failed' end
end

local function clear(api, game, v, own)
    if not stable(api, game, v, GAME_VALUE) then return true, 'waiting_for_stable_mission', false end
    local failure = write_flag(api, v, CLEAR, OWN_VALUE)
    if failure then return false, failure, false end
    remember(own, v)
    return true, 'avoidance_settings_ready', true
end

-- accepted (false stops the mod), status, active. own is the caller's table
-- for this mod's write. The flag is written only over the game's own value:
-- 0 needs nothing, 1 is cleared again (mission initialization reset it), and
-- any other value belongs to another writer: it is left alone and reported,
-- and polling goes on.
function patch.apply(api, game, own)
    local v, polling, status = inspect(api, game)
    if not v then
        forget(own)
        return polling, status, false
    end
    if v.enabled == OWN_VALUE then
        if not owns(own, v) then forget(own) end
        return true, 'avoidance_settings_ready', true
    end
    forget(own)
    if v.enabled ~= GAME_VALUE then return true, 'avoidance_flag_set_by_another_writer', false end
    return clear(api, game, v, own)
end

-- Puts the game's own value back, only over this mod's own write: the flag must
-- still hold 0 in the manager, owner, set and dimensions this mod cleared, with
-- the layout still valid, rechecked right before the store. Anything else is
-- left alone. Forgets the write either way. Returns ok (false: the write
-- failed) and the outcome.
function patch.restore(api, game, own)
    if own.manager == nil then return true, 'nothing_to_restore' end
    local v = inspect(api, game)
    local ours = v and v.enabled == OWN_VALUE and owns(own, v)
    forget(own)
    if not ours or not stable(api, game, v, OWN_VALUE) then return true, 'avoidance_left_unchanged' end
    local failure = write_flag(api, v, RESTORE, GAME_VALUE)
    if failure then return false, failure end
    return true, 'avoidance_restored'
end
-- The check runs ten times a second and stays interpreted, as apply always did
-- (its traces aborted). Compiled, these functions would add about 6.6 KB to the
-- game's shared code cache to save about 0.25 us per frame (offline, game's
-- lua51.dll); interpreted, a check still allocates nothing.
if jit and jit.off then
    for _, check in ipairs({slots, fields, pointer_at, count_at, near, zero, blank, layout_valid, inspect, remember,
        forget, owns, same_set, same_dims, stable, write_flag, clear, patch.apply, patch.restore}) do
        jit.off(check)
    end
end
return patch
