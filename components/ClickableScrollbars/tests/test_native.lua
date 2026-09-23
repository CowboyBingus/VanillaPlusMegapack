-- Offline model of the armory grid's own scroll model.
--
-- The offsets and the semantics under test were read out of the shipped build
-- (Steam 25327279, game.dll 73374BD4...):
--   controller + 523752        the item grid
--   grid + 597772              visible row slots
--   grid + 600452              items in the open category
--   grid + 600424              content height, px
--   grid + 0x8C0               the scrollable span (content - viewport)
--   grid + 0x8C8               the scrollbar's value, 0..1
--   grid + 622656 / 622660     first / last visible item
-- The game derives the pixel offset as `scroll = span * value` and re-solves the
-- visible range from its row tables; this file models that and runs the addon's
-- native layer against it. Nothing here writes to the game.
package.path = table.concat({arg[1] .. '/?.lua', arg[2], package.path}, ';')
rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local module = assert(loadfile(arg[2]))()
local ffi = require('ffi')

local function pack_u32(value) local word = ffi.new('uint32_t[1]', value); return ffi.string(word, 4) end
local function pack_u64(value) local word = ffi.new('uint64_t[1]', value); return ffi.string(word, 8) end
local function pack_f32(value) local real = ffi.new('float[1]', value); return ffi.string(real, 4) end
local function unpack_u32(text) local word = ffi.new('uint32_t[1]'); ffi.copy(word, text, 4); return tonumber(word[0]) end
local function unpack_u64(text) local word = ffi.new('uint64_t[1]'); ffi.copy(word, text, 8); return tonumber(word[0]) end
local function unpack_f32(text) local real = ffi.new('float[1]'); ffi.copy(real, text, 4); return tonumber(real[0]) end

local function check(name, condition, detail)
    if not condition then
        error(name .. (detail and (' (' .. tostring(detail) .. ')') or ''), 0)
    end
    print('ok ' .. name)
end

local GAME, DISPATCH, CONTROLLER = 0x0D000000, 0x0E000000, 0x0F000000
local GRID = CONTROLLER + 523752
local VALUE, SPAN, SCROLL, CONTENT = 0x8C8, 0x8C0, 600416, 600424
local ITEMS, COLUMNS, ROWS, SELECTED = 600452, 47540, 597772, 600308
local FIRST, LAST = 622656, 622660

-- A synthetic process: exact-address cells, so a read of the wrong offset finds
-- nothing instead of finding a plausible neighbour.
local function world(state)
    local cells = {}
    local put = function(address, text) cells[address] = text end
    local u32 = function(address, value) put(address, pack_u32(value)) end
    local u64 = function(address, value) put(address, pack_u64(value)) end
    local f32 = function(address, value) put(address, pack_f32(value)) end
    -- The grid controller registers itself as kind 224 in the dispatch table.
    u64(GAME + 0x3326e68, DISPATCH)
    u32(DISPATCH + 5740, 3)
    u64(DISPATCH + 5744, 0x1111111)
    u32(DISPATCH + 5752, 12)
    u64(DISPATCH + 5760, CONTROLLER)
    u32(DISPATCH + 5768, 224)
    u64(DISPATCH + 5776, 0x2222222)
    u32(DISPATCH + 5784, 7)
    for index=0,2 do u32(DISPATCH+5744+index*16+12,0) end
    -- The grid's own scroll model.
    u32(GRID + ROWS, state.rows or 5)
    u32(GRID + COLUMNS, state.columns or 4)
    -- Cache grouping is not the number of columns. Live grid: 3 columns and
    -- cache group size 9; the old validator rejected this valid list.
    u32(GRID + 602088, 9)
    u32(GRID + ITEMS, state.items or 42)
    u32(GRID + SELECTED, state.selected or 0)
    u32(GRID + FIRST, state.first or 11)
    u32(GRID + LAST, state.last or 20)
    u32(GRID + 602096, state.anchor or 12)
    f32(GRID + CONTENT, state.content or 4018)
    f32(GRID + SPAN, state.span or 3000)
    f32(GRID + VALUE, state.value or 0.5)
    f32(GRID + SCROLL, state.scroll or (state.span or 3000) * (state.value or 0.5))
    local panel = CONTROLLER + 318472
    local function widget(address, height, width, alpha, bottom)
        f32(address + 16, height); f32(address + 12, width)
        f32(address + 84, alpha); f32(address + 100, 4/3); f32(address + 140, 4/3)
        f32(address + 148, 1528); f32(address + 156, bottom or 138)
    end
    widget(GRID + 272, 738, 7, state.career and 0 or 1)
    widget(GRID + 888, 134.87964, 7, state.career and 0 or 1, 940)
    widget(panel + 195256, 762, 10, state.career and 1 or 0, 128)
    widget(panel + 195808, 439, 10, state.career and 1 or 0, 434)
    f32(panel + 2488 + 16, 1315); f32(panel + 2488 + 32, 1)
    f32(panel + 2488 + 4, 0); f32(panel + 2488 + 8, 320)
    return {cells = cells, grid = GRID}
end

local function reader(cells)
    local api = {}
    function api.module(name) return name == 'game.dll' and GAME or nil end
    function api.read(address, size)
        local result={}
        for offset=0,size-1 do
            local byte
            for start,cell in pairs(cells) do
                if address+offset>=start and address+offset<start+#cell then
                    byte=cell:sub(address+offset-start+1,address+offset-start+1);break
                end
            end
            if not byte then return nil end
            result[#result+1]=byte
        end
        return table.concat(result)
    end
    function api.pointer(bytes, offset)
        offset = offset or 0
        if type(bytes) ~= 'string' or #bytes < offset + 8 then return nil end
        return unpack_u64(bytes:sub(offset + 1, offset + 8))
    end
    return api
end

local function view(cells, journal)
    return {
        read_u32 = function(address)
            local bytes = cells[address]
            return bytes and #bytes >= 4 and unpack_u32(bytes) or nil
        end,
        read_f32 = function(address)
            local bytes = cells[address]
            return bytes and #bytes >= 4 and unpack_f32(bytes) or nil
        end,
        write_f32 = function(address, value)
            if address ~= GRID + VALUE and address ~= GRID + SCROLL then return false end
            cells[address] = pack_f32(value)
            journal[#journal + 1] = {address = address, value = value}
            return true
        end,
    }
end

local function locate(state, journal)
    local live = world(state)
    return module.native_locate(reader(live.cells), view(live.cells, journal)), live
end

-- 1. The grid resolves from the dispatch table, the way the shipped Armory mods
--    resolve their controller.
local journal = {}
local bridge = assert(locate({}, journal))
check('the armory grid resolves from the dispatch table', bridge.grid == GRID, bridge.grid)
check('re-resolving a controller keeps the same identity', locate({}, {}).key == bridge.key)
do
    local live = world({columns = 3})
    local api, memory = reader(live.cells), view(live.cells, {})
    local read, pointer, read_u32, read_f32 = api.read, api.pointer, memory.read_u32, memory.read_f32
    local function number(address) return tonumber(ffi.cast('uintptr_t', address)) end
    api.read = function(address, size) return read(number(address), size) end
    api.pointer = function(bytes, offset)
        local value = pointer(bytes, offset)
        return value and ffi.cast('uint8_t *', value) or nil
    end
    memory.read_u32 = function(address) return read_u32(number(address)) end
    memory.read_f32 = function(address) return read_f32(number(address)) end
    local first = assert(module.native_locate(api, memory))
    local second = assert(module.native_locate(api, memory))
    check('fresh FFI pointer wrappers keep the same controller identity', first.key == second.key)
end
local three_columns = assert(module.native_state(assert(locate({columns = 3}, {}))))
check('a three-column grid with nine-item cache groups is valid', three_columns.columns == 3)

-- 2. The model reads and is bounds-checked.
local state = assert(module.native_state(bridge))
check('the model reads the live layout', state.items == 42 and state.columns == 4 and state.rows == 5
    and state.first == 11 and state.last == 20, state.items)
check('the viewport is derived from content minus span',
    state.content == 4018 and state.span == 3000 and math.abs(state.viewport - 1018) < 0.01, state.viewport)

-- 3. One measured thumb plus the model gives the whole track: the thumb is
--    viewport/content of it and its top sits `value` of the way along the rest.
local track = assert(module.native_track(state, 498, 177))
check('the track is reconstructed from one measured thumb',
    math.abs(track.length - 177 * 738 / 134.87964) < 0.01 and math.abs(track.span - (track.length - 177)) < 0.01,
    track.length)
check('the thumb lands where it was measured',
    math.abs(track.top + state.value * track.span - 498) < 0.01, track.top)

-- 4. A track press aims the thumb's centre at the pointer; a held drag keeps the
--    grab point under it; both clamp the way the engine clamps.
-- A press centred on the thumb asks for the value it already holds: the page
-- click takes the thumb's middle to the pointer, not its top edge.
local thumb_centre = track.top + state.value * track.span + track.thumb / 2
local aimed = assert(module.native_value(state, thumb_centre, track))
check('a press on the thumb aims at its own value', math.abs(aimed - state.value) < 0.01, aimed)
check('a press below the track clamps to the end',
    module.native_value(state, track.top + track.length * 2, track) == 1)
check('a drag moves the value by the pointer distance',
    math.abs(module.native_value_at_grab(state, track, 500, 500 + track.span / 2) - (state.value + 0.5)) < 0.01)
check('a drag past the end clamps', module.native_value_at_grab(state, track, 500, 5000) == 1)
check('a drag above the start clamps', module.native_value_at_grab(state, track, 500, -5000) == 0)

-- 5. The write sets the value and the pixel offset the game derives from it.
local value = assert(module.native_set(bridge.memory, bridge.grid, state, 0.75))
check('the write sets the value and the derived pixel offset',
    value == 0.75 and #journal == 2 and journal[1].address == GRID + VALUE
    and journal[2].address == GRID + SCROLL
    and math.abs(journal[2].value - 0.75 * state.span) < 0.01, journal[2] and journal[2].value)
check('an out-of-range value is clamped', assert(module.native_set(bridge.memory, bridge.grid, state, 9)) == 1)
local foreign = {write_f32 = function() return false end}
check('a refused write is reported', module.native_set(foreign, bridge.grid, state, 0.5) == nil)
check('a write without a memory view is reported', module.native_set(nil, bridge.grid, state, 0.5) == nil)
local partial_value = state.value
local partial = {write_f32 = function(address, value)
    if address == GRID + SCROLL then return false end
    partial_value = value
    return true
end}
check('a failed pixel-offset write restores the previous value',
    module.native_set(partial, GRID, state, 0.9) == nil and partial_value == state.value)
check('an invalid span is rejected before any write',
    module.native_set(partial, GRID, {span = 0/0, value = state.value}, 0.9) == nil
    and partial_value == state.value)
-- The apply path is what the addon uses: the value, then the grid's own solver,
-- because a bare write leaves the visible range exactly where it was.
local sequence = {}
local calls = {
    stop = function(grid)
        assert(grid == GRID); sequence[#sequence + 1] = 'stop'
    end,
    scroll = function(bar, value)
        assert(bar == GRID + 272); sequence[#sequence + 1] = 'thumb'
        assert(bridge.memory.read_f32(GRID + VALUE) ~= value, 'prewrite bypasses the real thumb setter')
        bridge.memory.write_f32(GRID + VALUE, value)
    end,
    solve = function(grid)
        assert(grid == GRID); sequence[#sequence + 1] = 'layout'
        assert(math.abs(bridge.memory.read_f32(GRID + SCROLL) - 0.4 * state.span) < 0.01)
    end,
}
check('apply cancels animation and updates the thumb before list layout',
    module.native_apply(bridge, state, 0.4, calls) == 0.4
    and table.concat(sequence, ',') == 'stop,thumb,layout')
check('apply rejects an unresolved target', module.native_apply(foreign, state, 0.4, calls) == nil)

local career = assert(locate({career = true}, {}))
local career_model = assert(module.native_state(career))
check('Career owns its visible scrollbar instead of the hidden equipment grid',
    career.route == 'career' and career.key ~= bridge.key and career_model.span == 553)
check('Career reads the real container position with its padding',
    math.abs(career_model.value - 324/553) < 0.00001)
local positions = {}
local career_calls = {position = function(widget, x, y)
    assert(widget == CONTROLLER + 318472 + 2488 and x == 0)
    positions[#positions + 1] = y
end}
module.native_apply(career, career_model, 0, career_calls)
module.native_apply(career, career_model, 0.5, career_calls)
module.native_apply(career, career_model, 1, career_calls)
check('Career reaches both track ends and continuous positions between them',
    positions[1] == -4 and positions[2] == 553/2-4 and positions[3] == 549)
local screen = assert(module.native_screen_track(career_model, {x = -1920, y = 100, height = 1440}))
check('native geometry accounts for UI scale and window origin',
    screen.left == -392 and math.abs(screen.top - (1540 - 128 - 762*4/3)) < 0.001
    and math.abs(screen.thumb - 439*4/3) < 0.001)
local hidden = world({})
hidden.cells[GRID + 272 + 84] = pack_f32(0)
check('hidden scrollbars cannot capture a press',
    module.native_locate(reader(hidden.cells), view(hidden.cells, {})) == nil)

-- 6. A write is only believed when the game's own state moves with it.
check('an unchanged read-back is not movement', module.native_moved(state, state) == false)
check('a moved visible range counts as movement', module.native_moved(state, {first = 19, last = 28}))
-- The value and the pixel offset are what this addon writes: reading them back is
-- not evidence that the game moved, so they must never count as movement.
check('our own value and offset are not proof of movement',
    module.native_moved(state, {value = state.value + 0.2, scroll = state.scroll + 40}) == false)
check('a moved solver anchor counts as movement', module.native_moved(state, {anchor = 21}))

-- 7. A grid that no longer looks like this build is refused, not written to.
local hostile = {
    {columns = 0}, {columns = 99}, {rows = 0}, {rows = 99}, {items = 0},
    {items = 999999}, {content = 0}, {value = 4}, {span = 0},
}
for _, case in ipairs(hostile) do
    local candidate = assert(locate(case, {}))
    local refused, reason = module.native_state(candidate)
    check('a malformed grid is refused: ' .. next(case), refused == nil, reason)
end

-- 8. An unregistered grid never resolves, so nothing can be written.
local empty = world({})
empty.cells[DISPATCH + 5768] = nil
check('an unregistered grid is refused',
    module.native_locate(reader(empty.cells), view(empty.cells, {})) == nil)

-- Bindings/options uses a separate inline list with the same native scrollbar
-- setter. Its screen stack and visible widget must both agree before capture.
do
    local cells, screen, menu, owner, list = {}, 0x11000000, 0x12000000, 0x13000000,
        0x11000000 + 338344
    local put = function(a, value) cells[a] = value end
    put(GAME + 0x3326e68, pack_u64(DISPATCH))
    put(DISPATCH + 5740, pack_u32(1))
    put(DISPATCH + 5744, pack_u64(0x1111111) .. pack_u32(67) .. pack_u32(0))
    put(GAME + 0x347ce28, pack_u64(owner))
    put(owner + 0x429c, pack_u32(1) .. pack_u32(26) .. string.rep('\0', 12) .. pack_u32(2))
    put(GAME + 0x347ce38, pack_u64(menu))
    put(menu + 208, pack_u64(screen))
    put(screen + 12, '\1')
    local function widget(address, height, bottom)
        put(address + 12, pack_f32(6)); put(address + 16, pack_f32(height))
        put(address + 84, pack_f32(1)); put(address + 100, pack_f32(4/3))
        put(address + 140, pack_f32(4/3)); put(address + 148, pack_f32(1668.667))
        put(address + 156, pack_f32(bottom))
    end
    widget(list + 816, 806, 117.333)
    widget(list + 1432, 198.3, 544.444)
    put(list + 552, pack_f32(1168)); put(list + 2784, pack_f32(2470))
    put(list + 2792, pack_f32(0.473))
    local resolved = assert(module.native_locate(reader(cells), view(cells, {})))
    check('visible bindings page resolves its own bar',
        resolved.route == 'bindings' and resolved.bar == list + 816)
    local model = assert(module.native_state(resolved))
    check('bindings model reads the live list value and span',
        model.span == 2470 and math.abs(model.value - 0.473) < 0.001
        and model.geometry.thumb > 260)
    local applied = {}
    check('bindings updates the native bar and content in order',
        module.native_apply(resolved, model, 0.75,
            {scroll = function(bar, value) applied[#applied+1] = {bar, value} end,
             position = function(widget, x, y) applied[#applied+1] = {widget, x, y} end}) == 0.75
        and applied[1][1] == list + 816 and applied[1][2] == 0.75
        and applied[2][1] == list + 544 and applied[2][2] == 0
        and applied[2][3] == 0.75 * model.span)
    check('options movement requires the content to move, not just the thumb',
        not module.native_moved(model, {kind='bindings',scroll=model.scroll,rendered_thumb=40})
        and module.native_moved(model, {kind='bindings',scroll=model.scroll+5}))
    put(owner + 0x429c, pack_u32(1) .. pack_u32(25) .. string.rep('\0', 12) .. pack_u32(2))
    check('inactive bindings screen cannot capture',
        module.native_locate(reader(cells), view(cells, {})) == nil)
    put(owner + 0x429c, pack_u32(1) .. pack_u32(26) .. string.rep('\0', 12) .. pack_u32(2))
    put(list + 816 + 84, pack_f32(0))
    check('hidden bindings bar cannot capture',
        module.native_locate(reader(cells), view(cells, {})) == nil)
    local settings_screen, settings_list = 0x14000000, 0x14000000 + 4189984
    put(owner + 0x429c, pack_u32(1) .. string.rep('\0', 16) .. pack_u32(1))
    put(menu + 200, pack_u64(settings_screen))
    put(settings_screen + 12, '\1')
    widget(settings_list + 816, 806, 117.333)
    widget(settings_list + 1432, 548.679, 117.333)
    put(settings_list + 552, pack_f32(378)); put(settings_list + 2784, pack_f32(378))
    put(settings_list + 2792, pack_f32(1))
    local settings = assert(module.native_locate(reader(cells), view(cells, {})))
    local settings_model = assert(module.native_state(settings))
    check('settings page resolves its own native list',
        settings.route == 'settings' and settings.bar == settings_list + 816
        and settings_model.span == 378 and settings_model.value == 1)
    local input, consumed = 0x15000000, 0
    put(GAME + 0x347cf18, pack_u64(input))
    local consume = {consume=function(owner, action)
        check('settings captures the shared UI select action', owner==input and action==0xA00000000)
        consumed=consumed+1
    end}
    check('settings consumes input through the native action handler',
        module.native_settings_input(settings, consume) and consumed==1)
    check('bindings does not consume settings selection',
        not module.native_settings_input(resolved, consume) and consumed==1)
    check('refused input consumption cancels capture',
        not module.native_settings_input(settings, {consume=function() return false end}))
    check('input handler errors cancel capture',
        not module.native_settings_input(settings, {consume=function() error('refused') end}))
    cells[GAME + 0x347cf18]=nil
    check('unreadable input state cannot capture or call native code',
        not module.native_settings_input(settings, consume) and consumed==1)
end

print('native grid tests passed')

-- Exercise the real memory decoder: one bounded registry read even when full.
do
    local cells=world({}).cells
    cells[DISPATCH+5740]=pack_u32(64)
    for i=0,63 do
        cells[DISPATCH+5744+i*16]=pack_u64(CONTROLLER)
        cells[DISPATCH+5752+i*16]=pack_u32(7)
        cells[DISPATCH+5756+i*16]=pack_u32(0)
    end
    local api=reader(cells);local read=api.read;local calls=0
    api.read=function(a,n)calls=calls+1;return read(a,n)end
    assert(not module.native_locate(api) and calls==4,'absent owner must cost four reads')
    cells[DISPATCH+5752+63*16]=pack_u32(224)
    cells[GRID+272+84]=pack_f32(0);calls=0
    assert(not module.native_locate(api) and calls==6,'hidden owner must cost six reads')
    api.read=function(a,n)if n==1024 then return string.rep('x',1023)end;return read(a,n)end
    assert(not module.native_locate(api),'short registry snapshot must be rejected')
end
print('PASS: full registry batching, hidden/absent owners and truncated read refusal')
