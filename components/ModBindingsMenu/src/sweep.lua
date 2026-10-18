-- Mod Bindings Menu's binding sweep: what happens to the mappings of the native
-- actions that mod bindings use. src/mod_bindings_menu.lua runs this file once
-- as mbm_files.sweep(mbm); it adds sweep_bindings to mbm.
--
-- The dormant actions ship with developer defaults (controller buttons, the
-- mouse, Enter, Escape...) in the game's input configuration, and saved settings from v1 kept
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
--   unless other actions were restored with it, indicating a wholesale restore.
-- - An action handed over from an expired binding is cleared entirely.
-- - RepeatInterval button mappings become Press: the page has no selector for
--   RepeatInterval, which repeats while held.
-- - Native Revert copies only the current page's devices from DEFAULTS_MAP.
--   Keep that map free of developer defaults too, retaining the untouched
--   records privately so old saved lists can still be recognized and cleaned.
-- Per two-second sweep: two reads per registered action (live and defaults),
-- no allocation or write when unchanged. The extra defaults read detects a
-- native re-parse; while a binding page is open, defaults alone are checked
-- each frame so Revert always reads the sanitized source. This additional cost
-- is unmeasured in game; gameplay idle/poll frames add no reads.
-- The fixed slots' keyboard defaults (below) add two reads per fixed slot once
-- per session; re-adding them after a re-parse adds no read, only a write.
local mbm = ...
local ffi, bit = require('ffi'), require('bit')
local state, note, load_assignments = mbm.state, mbm.note, mbm.load_assignments
local read_into, map_bucket = mbm.read_into, mbm.map_bucket
local BINDING_MAP, DEFAULTS_MAP, RECORD_SIZE = mbm.BINDING_MAP, mbm.DEFAULTS_MAP, mbm.RECORD_SIZE
local MAPPINGS_OFFSET, MAPPING_SIZE, MAX_MAPPINGS = mbm.MAPPINGS_OFFSET, mbm.MAPPING_SIZE, mbm.MAX_MAPPINGS

-- Fixed slots whose keyboard default is Mod Bindings Menu's own: slot 1 Tab,
-- slots 3-7 F1, F5, F6, F7, F8. Each is the mapping the game's parser made
-- from the content/input replacement releases up to v2.3 shipped (build
-- 25480438, read live): {flags (Keyboard, Button, any device slot, Press,
-- virtual-key code in bits 20-31), key word (49 + virtual-key code)}. They are
-- now added while the game runs (add_keyboard_defaults below).
local SHIPPED_KEYBOARD_DEFAULT = {
    [12 * 65536 + 1] = {0x0090ff43, 0x3a}, [10 * 65536 + 1] = {0x0700ff43, 0xa1},
    [10 * 65536 + 4] = {0x0740ff43, 0xa5}, [10 * 65536 + 8] = {0x0750ff43, 0xa6},
    [10 * 65536 + 14] = {0x0760ff43, 0xa7}, [10 * 65536 + 9] = {0x0770ff43, 0xa8},
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
local originals = {}
local function at(index) return 2 + index * 5 end

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

-- The fixed slots' keyboard defaults, added while the game runs (no game file
-- is replaced), only after the build check passed. For each fixed slot,
-- added[code] holds the fingerprint of the game's stock list (taken from the
-- defaults map, which the game fills only from its own content/input) and the
-- record with the added list: the stock list with its first keyboard mapping
-- replaced by Mod Bindings Menu's (SHIPPED_KEYBOARD_DEFAULT) and any other
-- keyboard mapping dropped, as the replacement file had it. The game puts the
-- stock list back when it re-parses content/input: into the live map on a
-- device change (then its saved input settings follow) and into the defaults
-- map on a settings reset. A record read below that holds exactly the stock
-- list gets the added list again; no read is made for this.
local added = {}
-- The added record for code, from the stock record in words (whole, read in place).
local function derive(code, words)
    local key = SHIPPED_KEYBOARD_DEFAULT[code]
    local entry = {stock = fingerprint(words), record = ffi.new('MBM_u8[?]', RECORD_SIZE), placed = false}
    local out = ffi.cast('MBM_u32 *', entry.record)
    out[0] = words[0]
    local count = 0
    for index = 0, words[1] - 1 do
        local x = at(index)
        local keyboard = bit.band(words[x], 0xf) == KEYBOARD_DEVICE
        if not (keyboard and entry.placed) then
            local y = at(count)
            for word = 0, 4 do out[y + word] = words[x + word] end
            if keyboard then
                out[y], out[y + 1], out[y + 2], entry.placed = key[1], key[2], PRESS, true
            end
            count = count + 1
        end
    end
    out[1] = count
    entry.added = fingerprint(out)
    return entry
end
-- Writes the added list over the game's record at bucket, and over buffer read
-- from it, when the record holds the stock list. Returns whether it wrote.
local writes = 0
local function restore_added(bucket, buffer, words, code, which)
    local entry = added[code]
    if not entry.placed or entry.stock == entry.added or fingerprint(words) ~= entry.stock then return false end
    ffi.copy(buffer + 4, entry.record + 4, RECORD_SIZE - 4)
    ffi.copy(ffi.cast('MBM_u8 *', bucket) + 4, entry.record + 4, RECORD_SIZE - 4)
    writes = writes + 1
    if entry.ready then
        note(string.format('Added the keyboard default of %d:%d again: the game restored its stock list (%s).',
                           math.floor(code / 65536), code % 65536, which))
    end
    return true
end

-- Reads code's record from a binding map into buffer, whole: its cached address
-- (one read), else the map is indexed again. Returns the record's address.
-- A fixed slot's record holding the stock list gets the added list first.
local function read_record(map_offset, cache, code, buffer, words)
    local bucket = cache[code]
    for _ = 1, 2 do
        if bucket and read_into(bucket, buffer, RECORD_SIZE) and words[0] == code and words[1] <= MAX_MAPPINGS then
            if added[code] then
                restore_added(bucket, buffer, words, code, map_offset == DEFAULTS_MAP and 'reset defaults' or 'live')
            end
            return bucket
        end
        cache[code] = nil
        bucket = map_bucket(map_offset, code, cache)
    end
    return nil
end

-- Once per session, when native input is ready (after the build check): the
-- stock list of each fixed slot from the defaults map, then both maps get the
-- added list where they hold the stock one. Live records the game's saved
-- input settings already changed are left alone. Two reads per fixed slot;
-- a slot whose records cannot be read yet is retried by the next sweep.
local function add_keyboard_defaults()
    local pending, before = false, writes
    for code in pairs(SHIPPED_KEYBOARD_DEFAULT) do
        if not added[code] then
            local bucket = read_record(DEFAULTS_MAP, state.default_buckets, code, live, live_words)
            if bucket then
                local entry = derive(code, live_words)
                added[code] = entry
                if not entry.placed then
                    note(string.format('Fixed slot action %d:%d has no keyboard mapping; its default is not added.',
                                       math.floor(code / 65536), code % 65536))
                end
                restore_added(bucket, live, live_words, code)
                -- The live record: read_record writes the added list when it holds the stock one.
                read_record(BINDING_MAP, state.buckets, code, shipped, shipped_words)
                entry.ready = true
            else
                pending = true
            end
        end
    end
    state.keyboard_pending = pending
    if writes > before then
        note('Added Mod Bindings Menu\'s keyboard defaults to ' .. (writes - before) .. ' binding records.')
    end
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

-- Native defaults are not player settings. Capture them before sanitizing,
-- then keep that copy while the game holds our sanitized record. A re-parse
-- supplies a fresh original. Scratch buffers are reused; only the first read
-- of each registered action allocates its private record.
local function prepare_defaults(code)
    local bucket = read_record(DEFAULTS_MAP, state.default_buckets, code, live, live_words)
    if not bucket then return false end
    local found, saved = fingerprint(live_words), originals[code]
    if saved and found == saved.cleaned then return true end
    if not saved then
        saved = {bytes = ffi.new('MBM_u8[?]', RECORD_SIZE)}
        originals[code] = saved
    end
    ffi.copy(saved.bytes, live, RECORD_SIZE)
    saved.fingerprint = found
    ffi.copy(shipped, live, RECORD_SIZE)
    compact(bucket, code, true)
    saved.cleaned = fingerprint(live_words)
    return true
end

-- A fixed slot whose defaults record could not be read at activation is
-- tried again by each sweep; otherwise this only tests one flag.
local function retry_keyboard_defaults()
    if state.keyboard_pending then add_keyboard_defaults() end
end

-- Safe while a binding page is open: only its reset source changes, never the
-- live mappings being captured or the sweep's page/provenance bookkeeping.
local function sanitize_defaults()
    state.defaults_pending = false
    local ready = true
    for _, record in ipairs(state.order) do
        record.defaults_ready = prepare_defaults(record.code)
        ready = record.defaults_ready and ready
    end
    return ready
end

-- What the sweep does with an action this time: nothing (the list is as the
-- sweep left it), clear it, clean it the first time, a restored list, or a
-- list the player changed.
local CLEAR, FIRST, RESTORED, CHANGED = 1, 2, 3, 4

-- The plan for a binding's action, and for a restored list whether a single
-- capture could have made it (one mapping, not RepeatInterval).
local function plan(book, record)
    local code = record.code
    if not record.defaults_ready then return nil, nil, false end
    if not read_record(BINDING_MAP, state.buckets, code, live, live_words) then return nil, nil, false end
    local action = book.actions[code]
    if not action then return FIRST end
    if action.clear then return CLEAR end
    local list = fingerprint(live_words)
    if list == action.left then
        state.swept_counts[code] = live_words[1]
        return nil
    end
    if list == action.found or list == originals[code].fingerprint then
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
    if not bucket then return nil end
    local found, removed = fingerprint(live_words), 0
    if step == CLEAR then
        removed = live_words[1]
        write_record(bucket, 0)
    else
        local clean = step == FIRST or step == RESTORED and wholesale
        if clean then ffi.copy(shipped, originals[code].bytes, RECORD_SIZE) end
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
    retry_keyboard_defaults()
    -- A failed read cannot consume the binding-page visit: it still explains
    -- a deliberate single-key capture when the next sweep can read its data.
    if not sanitize_defaults() then return end
    local book = load_assignments()
    local restored, wholesale = 0, not state.page_visited
    for _, record in ipairs(state.order) do
        local step, single, readable = plan(book, record)
        if readable == false then return end
        record.plan = step
        if step == RESTORED then
            restored = restored + 1
            wholesale = wholesale or not single
        end
    end
    wholesale = wholesale or restored > 1
    local removed, complete = 0, true
    for _, record in ipairs(state.order) do
        if record.plan then
            local count = apply(book, record, wholesale)
            complete = count ~= nil and complete
            removed = removed + (count or 0)
        end
        record.plan = nil
    end
    if complete then state.page_visited = false end
    if removed > 0 then note('Removed ' .. removed .. ' inherited developer mappings.') end
end

mbm.sweep_bindings = sweep_bindings
mbm.sanitize_defaults = sanitize_defaults
mbm.add_keyboard_defaults = add_keyboard_defaults
