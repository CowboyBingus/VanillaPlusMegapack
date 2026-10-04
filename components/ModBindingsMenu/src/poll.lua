-- Mod Bindings Menu's batch polling: ModBindingsMenu.poll(ids, out) answers
-- several bindings in one call and writes each one's state and its edges into
-- arrays of a table the caller owns (README: "Polling several bindings").
-- src/mod_bindings_menu.lua runs this file once as mbm_files.poll(mbm); it adds
-- poll to mbm.
--
-- out.down[i] is exactly what is_down(ids[i]) would return at that point: the
-- record headers are read and checked one by one, in order, as is_down reads
-- them, so a sweep one of them starts comes before the later headers. Only the
-- input owner and the action states are read once for all: the owner, then one
-- stretch from the lowest to the highest action polled. For n available
-- bindings that is n + 2 reads instead of is_down's 3n, and nothing is
-- allocated once out's arrays hold every position.
local mbm = ...
local ffi, bit = require('ffi'), require('bit')
local state, live_header, active_screen = mbm.state, mbm.live_header, mbm.active_screen
local sweep_bindings, read_words, read_into = mbm.sweep_bindings, mbm.read_words, mbm.read_into
local word_pointer, words = mbm.word_pointer, mbm.words
local INPUT_OWNER_PTR_RVA, STATE_OFFSET, STRIDE = mbm.INPUT_OWNER_PTR_RVA, mbm.ACTION_STATE_OFFSET,
                                                  mbm.ACTION_STATE_STRIDE
local INVALID = 'invalid poll arguments'

-- The dormant actions' state entries (STRIDE bytes each, byte 0 the state) lie
-- in one stretch of the input owner: 9,345 bytes from the first (9:0) to the
-- last (12:1) state byte. A poll reads the part between its own lowest and
-- highest action into span, allocated at the first poll that reads states.
local FIRST, LAST = math.huge, -1
for _, entry in ipairs(mbm.DORMANT_ACTIONS) do
    FIRST, LAST = math.min(FIRST, entry[1] * 97 + entry[2]), math.max(LAST, entry[1] * 97 + entry[2])
end
local span
-- By position in ids: the state entry index this poll reads, or false.
local pending = {}

-- The arrays poll fills, created in out at its first poll. An out whose field
-- is something else is refused before anything is written.
local FIELDS = {'down', 'pressed', 'released', 'last'}
local function arrays(out)
    if type(out) ~= 'table' then return false end
    for _, field in ipairs(FIELDS) do
        if out[field] ~= nil and type(out[field]) ~= 'table' then return false end
    end
    for _, field in ipairs(FIELDS) do
        if out[field] == nil then out[field] = {} end
    end
    return true
end

-- One binding's record header, checked as is_down checks it: its state entry
-- index, false when its mapping count changed outside the binding pages (the
-- game restored a list: the sweep runs now, and the state is not read), or nil
-- (no binding).
local function header(id)
    local record = state.registry[id]
    if not record then return nil end
    local bucket, count = live_header(record)
    if not bucket then return nil end
    if count ~= state.swept_counts[record.code] and not active_screen() then
        sweep_bindings()
        return false
    end
    return record.group * 97 + record.action
end

-- Every header, in order. Sets pending and, for the bindings whose state is
-- not read, down; returns the lowest and highest state index to read (low >
-- high: none) and whether a sweep ran.
local function headers(ids, n, down)
    local ready, low, high, swept = state.build_rows ~= nil, LAST, FIRST, false
    for i = 1, n do
        local index = nil
        if ready then index = header(ids[i]) end
        if index then
            low, high = math.min(low, index), math.max(high, index)
        else
            down[i], swept = index, swept or index == false
        end
        pending[i] = index or false
    end
    return low, high, swept
end

-- One pending state: from the stretch when it was read, else on its own, as
-- is_down reads it; nil without the input owner.
local function entry_down(owner, whole, low, index)
    if whole then return span[STRIDE * (index - low)] ~= 0 end
    if owner and read_words(owner + STATE_OFFSET + STRIDE * index, 1) then
        return bit.band(words[0], 0xff) ~= 0
    end
    return nil
end

-- The pending states: the input owner, then the stretch from low to high in
-- one read (each entry on its own should that read fail).
local function read_states(n, down, low, high)
    span = span or ffi.new('MBM_u8[?]', STRIDE * (LAST - FIRST) + 1)
    local owner = read_words(state.base + INPUT_OWNER_PTR_RVA, 8) and word_pointer(0)
    local whole = owner and read_into(owner + STATE_OFFSET + STRIDE * low, span, STRIDE * (high - low) + 1)
    for i = 1, n do
        local index = pending[i]
        if index then down[i] = entry_down(owner, whole, low, index) end
    end
end

-- Edges against last: the state at the previous poll with this table that
-- trusted its frame (nil and false are up; an unavailable binding counts as
-- up). After a sweep nothing this frame is trusted: no edges, last kept.
local function edges(n, out, trusted)
    local down, pressed, released, last = out.down, out.pressed, out.released, out.last
    for i = 1, n do
        local now, before = down[i] == true, last[i] == true
        if trusted then
            pressed[i], released[i], last[i] = now and not before, before and not now, now
        else
            pressed[i], released[i], last[i] = false, false, before
        end
    end
end

-- ModBindingsMenu.poll(ids, out): true once out.down, out.pressed,
-- out.released and out.last hold positions 1 to #ids, or false and a reason.
function mbm.poll(ids, out)
    if type(ids) ~= 'table' or not arrays(out) then return false, INVALID end
    local n, down = #ids, out.down
    local low, high, swept = headers(ids, n, down)
    if low <= high then read_states(n, down, low, high) end
    edges(n, out, not swept)
    return true
end

-- Machine code. The loop over the headers is compiled: its branches go the same
-- way on every frame and its reads are FFI calls. Everything else runs once per
-- call or branches on which bindings are down, and compiled it mostly grew side
-- traces. In the game's lua51.dll, two simulated minutes of Ship Station
-- Hotkeys' six bindings read every frame (median of 10 fresh processes) took
-- 24.0 KB of machine code with poll compiled and 11.3 KB with this split, for
-- 4.02 and 4.44 us per frame (test process, the menu's update included); six
-- is_down calls took 14.3 KB and 5.97 us.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({arrays, entry_down, read_states, edges, mbm.poll}) do jit.off(fn) end
end
