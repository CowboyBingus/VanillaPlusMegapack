-- Mod Bindings Menu's binding sweep: what happens to the mappings of the native
-- actions that mod bindings use. src/mod_bindings_menu.lua runs this file once
-- as mbm_files.sweep(mbm); it adds sweep_bindings to mbm.
--
-- The dormant actions ship with developer defaults (controller buttons, the
-- mouse, Enter, Escape...) in input.config, and saved settings from v1 kept
-- them. They must never fire a mod binding, and a mapping the player chose must
-- never be deleted, even one equal to a developer default. So:
-- - Only actions a binding uses this session are swept. Another mod may use the
--   others natively, and an action whose binding registers late keeps its keys.
-- - The first time a binding uses an action, its mappings equal to one of the
--   action's shipped defaults (Mod Bindings Menu's own keyboard default on the
--   fixed slots aside) are cleared, once. The assignments file records it per
--   action: the session, and fingerprints of the list found and the list left.
-- - Afterwards every list the player makes is kept. Only a list that is exactly
--   the action's shipped defaults, or exactly the list found then, is cleaned
--   again: the game restored it (Revert, a config re-parse, a saved settings
--   file of an older version). After a binding page closes, an action changed
--   into one mapping a capture can make is the player's choice even then,
--   unless other actions were restored with it: a Revert restores them all.
-- - An action handed over from an expired binding is cleared entirely.
-- - RepeatInterval button mappings become Press: the page has no selector for
--   RepeatInterval, which repeats while held.
-- Per sweep: one read per action a binding uses, in place; while nothing
-- changed, nothing else (no allocation, no write).
local mbm = ...
local ffi, bit = require('ffi'), require('bit')
local state, note, load_assignments = mbm.state, mbm.note, mbm.load_assignments
local read_into, map_bucket = mbm.read_into, mbm.map_bucket
local BINDING_MAP, DEFAULTS_MAP, RECORD_SIZE = mbm.BINDING_MAP, mbm.DEFAULTS_MAP, mbm.RECORD_SIZE
local MAPPINGS_OFFSET, MAPPING_SIZE, MAX_MAPPINGS = mbm.MAPPINGS_OFFSET, mbm.MAPPING_SIZE, mbm.MAX_MAPPINGS

-- Fixed slots whose keyboard default is Mod Bindings Menu's own (input.config).
local SHIPPED_KEYBOARD_DEFAULT = {
    [12 * 65536 + 1] = true, [10 * 65536 + 1] = true, [10 * 65536 + 4] = true,
    [10 * 65536 + 8] = true, [10 * 65536 + 14] = true, [10 * 65536 + 9] = true,
}
local KEYBOARD_DEVICE = 3
local BUTTON_INPUT, REPEAT_INTERVAL, PRESS = 4, 8, 0
local FNV_BASIS = bit.tobit(2166136261)

-- The live record and the shipped defaults' record, read in place. A mapping
-- is five 32-bit words from byte 8 + 20 * index: flags (device bits 0-3, input
-- type 4-7, trigger 16-19), key (low half; the config parser leaves bytes 6-7
-- unset), trigger, combine, threshold.
local live, shipped = ffi.new('MBM_u8[?]', RECORD_SIZE), ffi.new('MBM_u8[?]', RECORD_SIZE)
local live_words, shipped_words = ffi.cast('MBM_u32 *', live), ffi.cast('MBM_u32 *', shipped)
local function at(index) return 2 + index * 5 end

-- Reads code's record from a binding map into buffer, whole: its cached address
-- (one read), else the map is indexed again. Returns the record's address.
local function read_record(map_offset, cache, code, buffer, words)
    local bucket = cache[code]
    for _ = 1, 2 do
        if bucket and read_into(bucket, buffer, RECORD_SIZE) and words[0] == code and words[1] <= MAX_MAPPINGS then
            return bucket
        end
        cache[code] = nil
        bucket = map_bucket(map_offset, code, cache)
    end
    return nil
end

-- FNV-1a over a record's mapping count and every mapping's words, bytes 6-7
-- aside: equal lists of mappings have equal fingerprints.
local function mix(hash, value)
    hash = bit.bxor(hash, value)
    return bit.tobit(hash * 403 + bit.lshift(hash, 24)) -- times 16777619 = 2^24 + 403, modulo 2^32
end
local function fingerprint(words)
    local hash = mix(FNV_BASIS, words[1])
    for index = 0, words[1] - 1 do
        local x = at(index)
        hash = mix(mix(mix(mix(mix(hash, words[x]), bit.band(words[x + 1], 0xffff)), words[x + 2]),
                       words[x + 3]), words[x + 4])
    end
    return hash
end

local function same_mapping(a, a_index, b, b_index)
    local x, y = at(a_index), at(b_index)
    return a[x] == b[y] and bit.band(a[x + 1], 0xffff) == bit.band(b[y + 1], 0xffff)
        and a[x + 2] == b[y + 2] and a[x + 3] == b[y + 3] and a[x + 4] == b[y + 4]
end

-- Whether live mapping index is one of the action's shipped developer defaults.
local function inherited(code, index)
    for other = 0, shipped_words[1] - 1 do
        local own = SHIPPED_KEYBOARD_DEFAULT[code] and bit.band(shipped_words[at(other)], 0xf) == KEYBOARD_DEVICE
        if not own and same_mapping(live_words, index, shipped_words, other) then return true end
    end
    return false
end

-- A RepeatInterval button mapping becomes Press, in both places the trigger is
-- stored (flag bits 16-19 and bytes 8-11). Returns whether it changed.
local function press(index)
    local x = at(index)
    local flags = live_words[x]
    if bit.band(bit.rshift(flags, 4), 0xf) ~= BUTTON_INPUT or live_words[x + 2] ~= REPEAT_INTERVAL then
        return false
    end
    local value = bit.bor(bit.band(flags, bit.bnot(0xf0000)), bit.lshift(PRESS, 16))
    if value < 0 then value = value + 0x100000000 end -- bit ops are signed 32-bit.
    live_words[x], live_words[x + 2] = value, 0
    return true
end

-- Writes the live record's first count mappings, the rest zeroed, and the
-- count over the game's record at bucket.
local function write_record(bucket, count)
    ffi.fill(live + MAPPINGS_OFFSET + count * MAPPING_SIZE, (MAX_MAPPINGS - count) * MAPPING_SIZE)
    live_words[1] = count
    local record = ffi.cast('MBM_u8 *', bucket)
    ffi.copy(record + MAPPINGS_OFFSET, live + MAPPINGS_OFFSET, MAX_MAPPINGS * MAPPING_SIZE)
    ffi.copy(record + 4, live + 4, 4)
end

-- Keeps the live mappings (all of them, or all but the inherited ones when
-- clean), RepeatInterval buttons turned into Press, and writes the record
-- back if anything changed. Returns how many mappings it removed.
local function compact(bucket, code, clean)
    local count, kept, changed = live_words[1], 0, false
    for index = 0, count - 1 do
        if not (clean and inherited(code, index)) then
            if kept < index then
                ffi.copy(live + MAPPINGS_OFFSET + kept * MAPPING_SIZE, live + MAPPINGS_OFFSET + index * MAPPING_SIZE,
                         MAPPING_SIZE)
            end
            changed = press(kept) or changed
            kept = kept + 1
        end
    end
    if changed or kept < count then write_record(bucket, kept) end
    return count - kept
end

-- What the sweep does with an action this time: nothing (the list is as the
-- sweep left it), clear it, clean it the first time, a restored list, or a
-- list the player changed.
local CLEAR, FIRST, RESTORED, CHANGED = 1, 2, 3, 4

local function shipped_fingerprint(code)
    return read_record(DEFAULTS_MAP, state.default_buckets, code, shipped, shipped_words)
        and fingerprint(shipped_words)
end

-- The plan for a binding's action, and for a restored list whether a single
-- capture could have made it (one mapping, not RepeatInterval).
local function plan(book, record)
    local code = record.code
    if not read_record(BINDING_MAP, state.buckets, code, live, live_words) then return nil end
    local action = book.actions[code]
    if not action then return FIRST end
    if action.clear then return CLEAR end
    local list = fingerprint(live_words)
    if list == action.left then
        state.swept_counts[code] = live_words[1]
        return nil
    end
    if list == action.found or list == shipped_fingerprint(code) then
        return RESTORED, live_words[1] == 1 and live_words[at(0) + 2] ~= REPEAT_INTERVAL
    end
    return CHANGED
end

-- Records what the sweep left: after the first clean or a clear, the session
-- and the list found too.
local function remember(book, code, step, found)
    local left, action = fingerprint(live_words), book.actions[code]
    if step == FIRST or step == CLEAR then
        book.actions[code] = {cleared = book.session, found = found, left = left}
        book.dirty = true
    elseif action.left ~= left then
        action.left, book.dirty = left, true
    end
end

-- Carries out a binding's plan; wholesale says restored lists are restores.
-- Returns how many mappings it removed.
local function apply(book, record, wholesale)
    local code, step = record.code, record.plan
    local bucket = read_record(BINDING_MAP, state.buckets, code, live, live_words)
    if not bucket then return 0 end
    local found, removed = fingerprint(live_words), 0
    if step == CLEAR then
        removed = live_words[1]
        write_record(bucket, 0)
    else
        local clean = step == FIRST or step == RESTORED and wholesale
        if clean and not read_record(DEFAULTS_MAP, state.default_buckets, code, shipped, shipped_words) then
            return 0
        end
        if step == RESTORED and not wholesale then
            note('Kept the single mapping chosen for ' .. record.id .. ' on a binding page, although it ' ..
                 'equals a developer default.')
        end
        removed = compact(bucket, code, clean)
    end
    remember(book, code, step, found)
    state.swept_counts[code] = live_words[1]
    return removed
end

-- Sweeps the actions of the bindings registered this session (see the top of
-- this file). Restored lists are restores unless a binding page closed since
-- the last sweep and the only restored list is one a single capture can make.
local function sweep_bindings()
    local book = load_assignments()
    local restored, wholesale = 0, not state.page_visited
    for _, record in ipairs(state.order) do
        local step, single = plan(book, record)
        record.plan = step
        if step == RESTORED then
            restored = restored + 1
            wholesale = wholesale or not single
        end
    end
    state.page_visited = false
    wholesale = wholesale or restored > 1
    local removed = 0
    for _, record in ipairs(state.order) do
        if record.plan then removed = removed + apply(book, record, wholesale) end
        record.plan = nil
    end
    if removed > 0 then note('Removed ' .. removed .. ' inherited developer mappings.') end
end

mbm.sweep_bindings = sweep_bindings
