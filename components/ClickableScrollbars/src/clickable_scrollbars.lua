-- HD2-Addon: mods/cowboybingus/clickable_scrollbars
-- Click-to-scroll: the visible menu's own scroll model follows the pointer.
-- Unsupported or hidden menus are inert; gestures never capture or inject input.
-- Loader-only: plaintext Lua, no DLL, no hook, no code patch. See docs/RESEARCH.md.

local module = {revision = 'v2.13'}

-- The engine's UI is reachable from Lua: equipment scrollbars are the game's own
-- ScrollBar objects, and driving one is a data write rather than synthesised input.
-- Anchors are the ones the shipped Armory mods use (game+0x347cd90 is the UI root,
-- game+0x3326e68 the dispatch table); nothing is written until the object is found.
function module.ui_bridge(create_api)
    if type(create_api) ~= 'function' then return nil, 'no api factory' end
    local ok, api = pcall(create_api)
    if not ok or type(api) ~= 'table' then return nil, 'api unavailable' end
    local ok2, result = pcall(function()
        if api.assert_thread then api.assert_thread() end
        local game = api.module('game.dll')
        if not game then return nil, 'game.dll unavailable' end
        local bridge = {api = api, game = game}
        bridge.ui = api.pointer(api.read(game + 0x347cd90, 8))
        bridge.dispatch = api.pointer(api.read(game + 0x3326e68, 8))
        return bridge
    end)
    if not ok2 then return nil, tostring(result) end
    if type(result) ~= 'table' then return nil, 'anchors unreadable' end
    return result
end

-- ------------------------------------------------------------- native grid

-- Armory and loadout equipment use a ScrollBar and a virtualized grid; Career
-- scrolls a widget container and derives its thumb during the frame update.
-- Both are driven directly, without synthesised input. These grid fields were
-- read from the shipped build (game.dll CC75948D...) and are bounds-checked;
-- nothing is written unless the whole chain resolves.
local GRID = {
    offset = 523752,        -- controller + ...            -> the item grid
    rows = 597772,          -- int, visible row slots
    row_heights = 597784,   -- float px, one per laid-out row
    row_items = 598808,     -- int, items in that row
    selected = 600308,      -- int, the highlighted item
    content = 600424,       -- float px, laid-out content height
    scroll = 600416,        -- float px, how far the list is scrolled
    span = 0x8C0,           -- float px, content - viewport (the scrollable span)
    value = 0x8C8,          -- float 0..1, the scrollbar's own value
    first = 622656,         -- int, first visible item
    last = 622660,          -- int, last visible item
    anchor = 602096,        -- int, the centre index the solver last published
    items = 600452,         -- int, items in the open category
    columns = 47540,        -- int, first visible row's actual item count
    kind = 602052,          -- int, category/layout type
    row_base = 2816,        -- first row slot
    row_stride = 44752,
    max_rows = 16,
    max_columns = 8,
    max_items = 100000,
    max_pixels = 1000000,
}

local CAREER = {offset = 318472, list = 2488, track = 195256, thumb = 195808,
                thumb_height = 196148, enabled = 196089, padding = 4}
local LOADOUT_GRID_OFFSET = 864032
-- Both the settings page and Bindings own inline virtual lists of the same
-- widget type. Page offsets were measured in Steam build 25327279.
local OPTIONS_LIST = {bar = 816, thumb = 1432,
                      scroll = 552, span = 2784, value = 2792}
local OPTIONS_PAGES = {
    [1] = {menu = 200, list = 4189984, route = 'settings'},
    [26] = {menu = 208, list = 338344, route = 'bindings'},
}
local GRID_SOLVER, SCROLL_SET, POSITION_SET, ANIMATION_STOP =
    0x18d2a90, 0x1794460, 0x1447610, 0x1439cb0
local INPUT_CONSUME, INPUT_STATE, UI_SELECT = 0x12fde90, 0x347cf18, 0xA00000000
module.native_signatures = {
    {GRID_SOLVER, '488bc45355565741544155415641574881ecf800000083b9'},
    {SCROLL_SET, '0f57d20f2fd1770cf30f1015f028c300f30f5dd1f30f1081'},
    {POSITION_SET, '48895c241848896c24204889542410565741574883ec20f3'},
    {ANIMATION_STOP, '40534883ec40488b05532320014833c448894424300fb601'},
    {INPUT_CONSUME, '40534883ec204c8bd14c8bca488bcae8dc7c28ff'},
}

local function native_key(pointer)
    if type(pointer) == 'cdata' then
        pointer = tonumber(require('ffi').cast('uintptr_t', pointer))
    end
    -- The game's tostring hides cdata values as "[cdata (deleted)]".
    return string.format('%.0f', pointer)
end

-- The native block is defined above the detector's own helpers, so it carries
-- the two small predicates it needs instead of capturing a local declared later.
-- Addresses are plain numbers in the offline model and FFI pointers in game.
local function native_clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function native_address(value)
    return type(value) == 'number' or type(value) == 'cdata'
end

-- Detector fallback geometry. Native hit testing uses widget transforms below;
-- if a measured thumb is used, preserve the game's actual thumb ratio (which
-- includes padding and need not equal viewport/content).
function module.native_track(model, thumb_top, thumb_length)
    if type(model) ~= 'table' or type(thumb_top) ~= 'number' or type(thumb_length) ~= 'number' then
        return nil
    end
    if thumb_length < 6 or not model.content or not model.viewport or model.viewport <= 0 then
        return nil
    end
    local ratio = model.thumb_ratio or model.viewport / model.content
    if ratio ~= ratio or ratio <= 0 or ratio >= 1 then return nil end
    local length = thumb_length / ratio
    if length ~= length or length <= thumb_length or length > GRID.max_pixels then return nil end
    return {top = thumb_top - model.value * (length - thumb_length), length = length,
            thumb = thumb_length, span = length - thumb_length}
end

-- Where a track press aims: the thumb's centre goes under the pointer, which is
-- what a native page click does.
function module.native_value(model, cursor_y, track)
    if type(model) ~= 'table' or type(track) ~= 'table' or not track.span or track.span <= 0 then
        return nil
    end
    local value = (cursor_y - track.top - track.thumb / 2) / track.span
    if value ~= value then return nil end
    return native_clamp(value, 0, 1)
end

-- Where a held drag aims: the bar keeps the grab point under the pointer, so the
-- value moves by exactly the distance the pointer moved.
function module.native_value_at_grab(model, track, press_y, cursor_y)
    if type(model) ~= 'table' or type(track) ~= 'table' or not track.span or track.span <= 0 then
        return nil
    end
    if type(model.value) ~= 'number' or type(press_y) ~= 'number' then return nil end
    local value = model.value + (cursor_y - press_y) / track.span
    if value ~= value then return nil end
    return native_clamp(value, 0, 1)
end

-- The write itself: the value plus the pixel offset the game derives from it.
-- Both are written so the model is consistent whichever one the engine reads
-- first, and both are bounded before they leave.
function module.native_set(memory, grid, model, value)
    if type(memory) ~= 'table' or not native_address(grid) or type(model) ~= 'table' then
        return nil, 'not ready'
    end
    if type(value) ~= 'number' or value ~= value then return nil, 'invalid value' end
    if type(model.span) ~= 'number' or model.span <= 0 or model.span > GRID.max_pixels
        or model.span ~= model.span then return nil, 'invalid span' end
    value = native_clamp(value, 0, 1)
    if not memory.write_f32 or not memory.write_f32(grid + GRID.value, value) then
        return nil, 'write refused'
    end
    if not memory.write_f32(grid + GRID.scroll, value * model.span) then
        memory.write_f32(grid + GRID.value, model.value)
        return nil, 'scroll write refused'
    end
    return value
end

-- Use the same setters and layout sequence as the game's scroll handlers.
-- A raw value write skips the thumb update; an active animation can overwrite
-- the requested position. Native calls execute from the loader's frame callback.
function module.native_calls(bridge)
    local ffi = require('ffi')
    local calls = {}
    function calls.stop(grid)
        if ffi.cast('uint8_t *', grid + 600322)[0] ~= 0 then
            ffi.cast('void (*)(void *)', bridge.game + ANIMATION_STOP)(grid + 600320)
        end
    end
    function calls.scroll(bar, value)
        ffi.cast('void (*)(void *, float)', bridge.game + SCROLL_SET)(bar, value)
    end
    function calls.position(widget, x, y)
        -- The engine passes its two-float vector in the second integer register.
        -- An FFI struct argument is not interchangeable with that ABI.
        local xy = ffi.new('float[2]', {x, y})
        local packed = ffi.new('uint64_t[1]')
        ffi.copy(packed, xy, 8)
        ffi.cast('void (*)(void *, uint64_t)', bridge.game + POSITION_SET)(widget, packed[0])
    end
    function calls.solve(grid)
        ffi.cast('void (*)(void *)', bridge.game + GRID_SOLVER)(grid)
    end
    function calls.consume(input, action)
        -- Match the game's buttons: -1 consumes this action until release.
        ffi.cast('void (*)(void *, uint64_t, float)', bridge.game + INPUT_CONSUME)(
            input, ffi.new('uint64_t', action), -1)
    end
    return calls
end

function module.native_apply(bridge, model, value, calls)
    if type(bridge) ~= 'table' or not bridge.memory or not model
        or type(value) ~= 'number' or value ~= value
        or not model.span or model.span <= 0 or model.span ~= model.span
        or model.span > GRID.max_pixels then return nil, 'invalid native target' end
    value = native_clamp(value, 0, 1)
    local ok, err = pcall(function()
        calls = calls or module.native_calls(bridge)
        if bridge.route == 'career' then
            -- Career scrolls a container. Its frame update derives the thumb
            -- from (container.y + padding) / (content - viewport).
            calls.position(bridge.panel + CAREER.list, model.list_x,
                           value * model.span - CAREER.padding)
        elseif bridge.route == 'bindings' or bridge.route == 'settings' then
            -- The game's list input handler updates both objects in this order:
            -- the scrollbar value, then the content container's vertical
            -- position. Updating only the bar moves the thumb but not rows.
            calls.scroll(bridge.bar, value)
            calls.position(bridge.grid + 544, 0, value * model.span)
        else
            -- Follow the game's wheel handler: stop an existing animation,
            -- update the scrollbar (including its rendered thumb), then layout.
            -- Writing value first would make the native setter skip its work.
            calls.stop(bridge.grid)
            calls.scroll(bridge.grid + 272, value)
            if not bridge.memory.write_f32(bridge.grid + GRID.scroll, value * model.span) then
                calls.scroll(bridge.grid + 272, model.value)
                error('scroll write refused', 0)
            end
            calls.solve(bridge.grid)
        end
    end)
    if not ok then return nil, tostring(err) end
    return value
end

-- Settings rows and tabs both read UI_SELECT, including its held value. The
-- list's 0.5-second timer is not a capture gate: its update adds dt before row
-- input, and tabs bypass it entirely. Consume the selection through the same
-- engine routine used by buttons; it clears all frame copies and held values.
-- The OS button/cursor remain untouched and continue driving our scroll model.
function module.native_settings_input(bridge, calls)
    if not bridge or bridge.route ~= 'settings' or not bridge.api or not bridge.game then
        return nil, 'not a settings list'
    end
    local ok, result = pcall(function()
        local input = bridge.api.pointer(bridge.api.read(bridge.game + INPUT_STATE, 8))
        if not input then return false end
        calls = calls or module.native_calls(bridge)
        return calls.consume(input, UI_SELECT) ~= false
    end)
    if not ok or not result then return nil, 'settings input consume failed' end
    return true
end

function module.native_moved(before, after)
    if type(before) ~= 'table' or type(after) ~= 'table' then return false end
    if before.kind == 'bindings' or before.kind == 'settings' then
        -- The options route never writes the content offset directly; this is
        -- evidence that the game's container position setter answered.
        return after.kind == before.kind and before.scroll and after.scroll
            and math.abs(before.scroll - after.scroll) > 0.1 or false
    end
    -- Only the fields the game itself derives count: the value and the pixel
    -- offset are what this addon writes, so comparing them with themselves would
    -- read a write back as a success.
    if before.first and after.first and after.first ~= before.first then return true end
    if before.last and after.last and after.last ~= before.last then return true end
    if before.anchor and after.anchor and after.anchor ~= before.anchor then return true end
    if before.rendered_thumb and after.rendered_thumb
        and math.abs(before.rendered_thumb - after.rendered_thumb) > 0.1 then return true end
    return false
end

-- A memory view is the only thing the native layer needs, so the code that runs
-- in game is the code the offline model exercises.
function module.native_memory(api)
    if type(api) ~= 'table' or type(api.read) ~= 'function' then return nil, 'no reader' end
    local ok, ffi = pcall(require, 'ffi')
    if not ok then return nil, 'ffi unavailable' end
    local word, real = ffi.new('uint32_t[1]'), ffi.new('float[1]')
    local memory = {api = api, float = real, word = word}
    function memory.read_u32(address)
        local bytes = api.read(address, 4)
        if type(bytes) ~= 'string' or #bytes < 4 then return nil end
        ffi.copy(word, bytes, 4)
        return tonumber(word[0])
    end
    function memory.read_f32(address)
        local bytes = api.read(address, 4)
        if type(bytes) ~= 'string' or #bytes < 4 then return nil end
        ffi.copy(real, bytes, 4)
        return tonumber(real[0])
    end
    function memory.write_f32(address, value)
        if type(value) ~= 'number' or value ~= value or math.abs(value) > GRID.max_pixels then return false end
        local ok2 = pcall(function() ffi.cast('float *', address)[0] = value end)
        return ok2
    end
    return memory
end

-- The reader the addon ships with: the same FFI surface the other Armory mods
-- use (module handle plus a read of this process), with a bounded read.
function module.native_api()
    local ok, ffi = pcall(require, 'ffi')
    if not ok or not ffi.abi('64bit') then return nil, 'ffi unavailable' end
    pcall(ffi.cdef, [[
        void *GetModuleHandleA(const char *name);
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
    ]])
    local kernel32 = ffi.load('kernel32')
    local process = kernel32.GetCurrentProcess()
    local api = {}
    function api.module(name)
        local handle = kernel32.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end
    function api.read(address, size)
        if type(size) ~= 'number' or size < 1 or size > 32768 or size % 1 ~= 0 then return nil end
        local buffer, count = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        if kernel32.ReadProcessMemory(process, address, buffer, size, count) == 0 then return nil end
        if count[0] ~= size then return nil end
        return ffi.string(buffer, size)
    end
    function api.pointer(bytes, offset)
        offset = offset or 0
        if type(bytes) ~= 'string' or offset < 0 or offset + 8 > #bytes then return nil end
        local value = ffi.new('uintptr_t[1]')
        ffi.copy(value, bytes:sub(offset + 1, offset + 8), 8)
        if value[0] < 0x10000 or value[0] >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value[0])
    end
    -- Refuse all native scrolling if any called routine differs from this build.
    local game = api.module('game.dll')
    for _, entry in ipairs(module.native_signatures) do
        local bytes = entry[2]:gsub('..', function(hex) return string.char(tonumber(hex, 16)) end)
        if not game or api.read(game + entry[1], #bytes) ~= bytes then
            return nil, 'unsupported native scroll routine'
        end
    end
    return api
end

-- Resolve the live equipment grid from its screen's registered controller.
-- Ship Armory uses kind 224; the mission loadout picker uses kind 229 and embeds
-- the same grid at a different controller offset in build 25327279.
function module.native_locate(api, memory)
    if type(api) ~= 'table' then return nil, 'no reader' end
    memory = memory or module.native_memory(api)
    if not memory then return nil, 'no memory view' end
    local game = api.module('game.dll')
    if not game then return nil, 'game.dll unavailable' end
    local dispatch = api.pointer(api.read(game + 0x3326e68, 8))
    if not dispatch then return nil, 'dispatch table unavailable' end
    local count = memory.read_u32(dispatch + 5740)
    if not count or count < 1 or count > 64 then return nil, 'dispatch bounds changed' end
    -- Snapshot the bounded registry once instead of a system call per row.
    local rows = api.read(dispatch + 5744, count * 16)
    if type(rows) ~= 'string' or #rows ~= count * 16 then return nil, 'dispatch rows unreadable' end

    local has_armory, has_loadout = false, false
    for index = 0, count - 1 do
        local kind = rows:byte(index * 16 + 9)
            + rows:byte(index * 16 + 10) * 256
            + rows:byte(index * 16 + 11) * 65536
            + rows:byte(index * 16 + 12) * 16777216
        if kind == 224 then has_armory = true
        elseif kind == 229 then has_loadout = true end
    end
    local active_kind
    if has_loadout then
        -- The loadout controller can remain registered while a different UI
        -- state is on top. Use the screen stack when readable; captured tests
        -- without that optional anchor still use visible-widget validation.
        local ok, value = pcall(function()
            local stack_owner = api.pointer(api.read(game + 0x347ce28, 8))
            if not stack_owner then return nil end
            local stack = api.read(stack_owner + 0x429c, 24)
            if type(stack) ~= 'string' or #stack < 24 then return nil end
            local function word(offset)
                local a, b, c, d = stack:byte(offset + 1, offset + 4)
                if not d then return nil end
                return a + b * 256 + c * 65536 + d * 16777216
            end
            local depth = word(20)
            if not depth or depth < 1 or depth > 5 then return false end
            local top = word((depth - 1) * 4)
            if top == 5 then return 224 end
            if top == 14 then return 229 end
            return false
        end)
        if ok then active_kind = value end
        if active_kind == false then return nil, 'unsupported UI screen' end
    end

    for index = 0, count - 1 do
        local offset = index * 16
        local kind = rows:byte(offset + 9)
            + rows:byte(offset + 10) * 256
            + rows:byte(offset + 11) * 65536
            + rows:byte(offset + 12) * 16777216
        if (kind == 224 or kind == 229) and (not active_kind or kind == active_kind) then
            local controller = api.pointer(rows, offset)
            if not controller then return nil, 'equipment controller unavailable' end
            local grid_offset = kind == 224 and GRID.offset or LOADOUT_GRID_OFFSET
            local bridge = {api = api, memory = memory, game = game, controller = controller,
                            kind = kind, grid = controller + grid_offset,
                            panel = kind == 224 and controller + CAREER.offset or nil}
            -- Resolved alpha includes parent visibility. The equipment grid
            -- remains allocated behind Career and must never own its gestures.
            if bridge.panel and (memory.read_f32(bridge.panel + CAREER.track + 84) or 0) > 0.95 then
                bridge.route = 'career'
                bridge.bar, bridge.thumb = bridge.panel + CAREER.track, bridge.panel + CAREER.thumb
            elseif (memory.read_f32(bridge.grid + 272 + 84) or 0) > 0.95 then
                bridge.route = 'grid'
                bridge.bar, bridge.thumb = bridge.grid + 272, bridge.grid + 888
            else
                if active_kind then return nil, 'no visible equipment scrollbar' end
                -- A stale/hidden controller may precede the visible owner in
                -- the registry; keep looking before declaring the menu inert.
                bridge = nil
            end
            if bridge then
                bridge.key = native_key(controller) .. ':' .. tostring(kind) .. ':' .. bridge.route
                return bridge
            end
        end
    end
    -- The options pages have no equipment controller registration. Their own
    -- page pointer and active screen ID gate access to each inline list.
    local ok, bindings = pcall(function()
        local owner = api.pointer(api.read(game + 0x347ce28, 8))
        if not owner then return nil end
        local stack = api.read(owner + 0x429c, 24)
        if not stack or #stack ~= 24 then return nil end
        local function word(offset)
            local a, b, c, d = stack:byte(offset + 1, offset + 4)
            return a and d and (a + b * 256 + c * 65536 + d * 16777216)
        end
        local depth = word(20)
        if not depth or depth < 1 or depth > 5 then return nil end
        local screen_id = word((depth - 1) * 4)
        local page = OPTIONS_PAGES[screen_id]
        if not page then return nil end
        local menu = api.pointer(api.read(game + 0x347ce38, 8))
        local screen = menu and api.pointer(api.read(menu + page.menu, 8))
        if not screen or api.read(screen + 12, 1) ~= '\1' then return nil end
        local list = screen + page.list
        local bar, thumb = list + OPTIONS_LIST.bar, list + OPTIONS_LIST.thumb
        if (memory.read_f32(bar + 84) or 0) <= 0.95 then return nil end
        return {api = api, memory = memory, game = game, controller = screen,
                grid = list, bar = bar, thumb = thumb, route = page.route,
                kind = screen_id, key = native_key(screen) .. ':' .. screen_id .. ':' .. page.route}
    end)
    if ok and bindings then return bindings end
    return nil, (has_armory or has_loadout) and 'no visible equipment scrollbar'
        or 'equipment grid not registered'
end

-- Read the grid's own scroll model, with the bounds the offsets were measured
-- under. A model that does not look like this build's grid is refused rather
-- than written to.
function module.native_state(bridge)
    if type(bridge) ~= 'table' or not native_address(bridge.grid) or type(bridge.memory) ~= 'table' then
        return nil, 'not resolved'
    end
    local memory, grid = bridge.memory, bridge.grid
    local function u32(offset) return memory.read_u32(grid + offset) end
    local function f32(offset) return memory.read_f32(grid + offset) end
    local function widget_f32(widget, offset) return memory.read_f32(widget + offset) end
    local function geometry(model)
        local bar, thumb = bridge.bar, bridge.thumb
        local height, width = widget_f32(bar, 16), widget_f32(bar, 12)
        local sx, sy = widget_f32(bar, 100), widget_f32(bar, 140)
        local left, bottom = widget_f32(bar, 148), widget_f32(bar, 156)
        local thumb_height = widget_f32(thumb, 16)
        if not (height and width and sx and sy and left and bottom and thumb_height) then
            return nil, 'scrollbar geometry unreadable'
        end
        for _, number in ipairs({height, width, sx, sy, left, bottom, thumb_height}) do
            if number ~= number or math.abs(number) > GRID.max_pixels then
                return nil, 'scrollbar geometry out of range'
            end
        end
        if height <= 0 or width <= 0 or sx <= 0 or sy <= 0 or thumb_height <= 0
            or thumb_height >= height then return nil, 'scrollbar not scrollable' end
        model.thumb_ratio = thumb_height / height
        model.geometry = {left = left, bottom = bottom, width = width * sx,
                          length = height * sy, thumb = thumb_height * sy}
        model.rendered_thumb = widget_f32(thumb, 156)
        return model
    end
    if bridge.route == 'career' then
        local list = bridge.panel + CAREER.list
        local height, scale = widget_f32(list, 16), widget_f32(list, 32)
        local viewport = widget_f32(bridge.bar, 16)
        local y, x = widget_f32(list, 8), widget_f32(list, 4)
        if not (height and scale and viewport and y and x) then return nil, 'career unreadable' end
        local content, span = height * scale, height * scale - viewport
        if content ~= content or content > GRID.max_pixels or span ~= span or span <= 0
            or y ~= y or math.abs(y) > GRID.max_pixels or x ~= x then return nil, 'career out of range' end
        return geometry({content = content, span = span, viewport = viewport,
            scroll = y + CAREER.padding, list_x = x,
            value = native_clamp((y + CAREER.padding) / span, 0, 1), kind = 'career'})
    end
    if bridge.route == 'bindings' or bridge.route == 'settings' then
        local span, value, scroll = f32(OPTIONS_LIST.span), f32(OPTIONS_LIST.value),
            f32(OPTIONS_LIST.scroll)
        local viewport = widget_f32(bridge.bar, 16)
        if not (span and value and scroll and viewport) or span ~= span or value ~= value
            or scroll ~= scroll or span <= 0 or span > GRID.max_pixels
            or value < -0.001 or value > 1.001 or viewport <= 0
            or viewport > GRID.max_pixels or scroll < -1 or scroll > span + 1 then
            return nil, 'bindings list out of range'
        end
        return geometry({content = span + viewport, span = span, viewport = viewport,
            value = native_clamp(value, 0, 1), scroll = scroll, kind = bridge.route})
    end
    local model = {columns = u32(GRID.columns), rows = u32(GRID.rows), items = u32(GRID.items),
                   kind = u32(GRID.kind),
                   selected = u32(GRID.selected), first = u32(GRID.first), last = u32(GRID.last),
                   anchor = u32(GRID.anchor),
                   content = f32(GRID.content), span = f32(GRID.span), value = f32(GRID.value),
                   scroll = f32(GRID.scroll)}
    if not (model.columns and model.rows and model.items) then return nil, 'grid state unreadable' end
    if model.columns < 1 or model.columns > GRID.max_columns then return nil, 'grid columns out of range' end
    if model.rows < 1 or model.rows > GRID.max_rows then return nil, 'grid rows out of range' end
    if model.items < 1 or model.items > GRID.max_items then return nil, 'grid item count out of range' end
    if not model.content or model.content ~= model.content or model.content <= 0
        or model.content > GRID.max_pixels then
        return nil, 'grid content out of range'
    end
    if not model.value or model.value ~= model.value or model.value < -0.001 or model.value > 1.001 then
        return nil, 'grid value out of range'
    end
    if not model.span or model.span ~= model.span or model.span <= 0 or model.span > GRID.max_pixels then
        return nil, 'grid span out of range'
    end
    model.value = native_clamp(model.value, 0, 1)
    model.viewport = model.content - model.span
    if model.viewport <= 0 then return nil, 'grid not scrollable' end
    return geometry(model)
end

-- Translate the native bottom-left origin to desktop pointer coordinates.
function module.native_screen_track(model, viewport)
    local g = model and model.geometry
    if not g or not viewport or not viewport.height then return nil end
    return {left = viewport.x + g.left, right = viewport.x + g.left + g.width,
            top = viewport.y + viewport.height - g.bottom - g.length,
            length = g.length, thumb = g.thumb, span = g.length - g.thumb}
end

-- Pixel constants are quoted for a 1440 px tall viewport and scaled to the interface;
-- ini values stay absolute and the bar's measured thickness overrides the estimate.
local DEFAULTS = {
    enabled = true,
    -- Capture geometry.
    strip_width = 96,        -- px captured horizontally, centred on the cursor
    window = 460,            -- px captured vertically either side of the cursor
    window_max = 1400,       -- widest the strip may grow to when a thumb does not fit
    narrow_width = 40,       -- px wide second pass once a bar column is known
    narrow_window = 420,     -- px tall second pass
    bar_cache_ms = 60000,    -- how long a known bar column is trusted
    -- Thumb classification.
    min_height = 44,         -- shortest accepted thumb, px
    max_height_ratio = 0.94, -- longest accepted thumb, fraction of the capture
    min_width = 6,           -- narrowest accepted thumb, px
    max_width = 28,          -- widest accepted thumb, px
    min_luma = 105,          -- thumb brightness window
    max_luma = 220,
    min_luma_floor = 40,     -- absolute floor once the threshold is adapted
    min_contrast = 30,       -- thumb must be this much brighter than the strip's dark quartile
    local_contrast = true,   -- and brighter than the pixels beside it (rejects wide bright areas)
    local_offset = 16,       -- px to either side used for that comparison
    max_spread = 18,         -- max channel spread for "neutral grey"
    min_fill = 0.72,         -- fraction of grey pixels required inside a run
    max_bridge = 160,        -- masked rows a run may bridge (cursor overlay)
    max_gap = 6,             -- unmasked rows a run may bridge (small bright overlay)
    max_variance = 14,       -- max deviation from the thumb's median brightness
    min_uniformity = 0.85,   -- fraction of samples that must stay within it
    edge_contrast = 25,      -- background beside the thumb must be this much darker
    -- Click interpretation.
    thumb_margin = 9,        -- px around the thumb treated as the thumb
    column_tolerance = 12,   -- px the cursor may sit outside the thumb column
    click_contrast = 25,     -- click pixel must be this much darker than the bar
    -- Measured bounding box of the pointer's sprite: inside it, coloured or over-bright
    -- rows are bridged so the thumb stays whole under the pointer.
    cursor_mask = {x0 = -72, x1 = 72, y0 = -72, y1 = 72},
    -- Which keys follow the display scale rather than staying absolute.
    scaled_keys = {'strip_width', 'window', 'narrow_width', 'narrow_window', 'min_height', 'min_width',
                   'max_width', 'local_offset', 'max_bridge', 'max_gap', 'thumb_margin',
                   'column_tolerance', 'drag_threshold', 'drag_max_step_px',
                   'probe_step',
                   'calibration_min_px', 'calibration_max_px',
                   'center_tolerance', 'settle_stable_px'},
    cursor_mask_radius = 72, -- px, scaled with the display
    -- Aiming and following. The seed is the step measured live on the Armory list:
    -- 12.998 px of thumb travel per notch over 14 notches at the reference scale.
    default_pixels_per_notch = 13, -- measured wheel step before calibration
    bar_reference_width = 10,      -- the bar's thickness at that reference scale
    center_tolerance = 4,    -- px of aimed error that counts as centred
    jump_max_notches = 120,  -- notches one track-click jump may send
    emit_max_notches = 16,   -- notches one frame may inject; the rest follows next frame
    correction_notches = 40, -- notches one settle correction may add
    max_corrections = 2,     -- settle corrections per jump, each of which must shrink the error
    settle_delay_ms = 200,   -- wait after a jump before measuring the thumb
    settle_interval_ms = 60, -- between settle measurements
    settle_stable_px = 2,    -- movement below this counts as stopped
    settle_checks = 8,       -- measurements before a jump is given up
    drag_threshold = 10,     -- px of vertical movement that starts a drag
    drag_max_step_px = 220,  -- a larger single-frame jump is a pointer teleport
    drag_max_notches = 40,   -- hard cap on the notches one drag frame may send
    -- Accepted for older INIs; wheel input now stays inside the exact column.
    drag_column_margin = 2.8,
    drag_verify_notches = 3, -- notches before a drag re-checks the thumb
    -- Gap between drag re-checks: each costs ~1.9 ms measured, and every check skipped
    -- is another stretch of notches spent past a thumb the game has clamped.
    drag_verify_ms = 45,
    drag_stall_confirmations = 2, -- readings in a row that must show no thumb movement
    track_clamp_max_notches = 12,  -- notches a learned track end may block before it is dropped
    -- Drive the value and run the layout solver together. The old bare value
    -- write could move only the thumb; the solver also updates the visible rows.
    native = 1,
    native_verify_ms = 200,
    calibration_samples = 7, -- observed steps kept for the median
    calibration_min_px = 4,  -- accepted observed px/notch window
    calibration_max_px = 60,
    -- Diagnostics.
    trace_lines = 48,        -- decisions kept for the log
    trace_events = 0,        -- 1 records every emission and drag step
    diagnostics = 0,         -- opt-in interaction traces and periodic disk writes
    log_interval_ms = 5000,  -- shortest gap between log writes
    cooldown_ms = 0,         -- shortest gap between two track-click jumps
    min_capture_interval_ms = 40,
    use_window_capture = 1,  -- 1 tries the game's own window DC before the desktop DC
    scale_geometry = 1,      -- 1 scales the pixel geometry to the display height
    probe_step = 8,             -- rows between column probes (a run is far taller)
    -- Captures are the only expensive work here; a press on a bar that was already
    -- measured is answered from that analysis and the notches sent since.
    burst_cache_ms = 250,       -- how long a recent analysis may classify a press
    burst_capture_every = 3,    -- force a real capture after this many skips
    capture_budget_ms_per_s = 60, -- capture time the addon may spend per second
    capture_budget_floor_ms_per_s = 30, -- floor for that budget when frames are slow
    error_limit = 8,         -- frame errors tolerated before the addon stops
    dump_captures = 0,       -- diagnostic BMP dumps; 0 keeps nothing on disk
}

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function luminance(r, g, b)
    return (r * 299 + g * 587 + b * 114) / 1000
end

-- ---------------------------------------------------------------- detection

-- A capture sample exposes width, height, origin_x, origin_y and
-- rgb(x, y) -> r, g, b for strip-local coordinates.

function module.thumb_pixel(sample, x, y, options)
    local r, g, b = sample.rgb(x, y)
    if r == nil then return nil end
    local high, low = r, r
    if g > high then high = g end
    if b > high then high = b end
    if g < low then low = g end
    if b < low then low = b end
    if high - low > options.max_spread then return nil end
    local value = luminance(r, g, b)
    if value < options.min_luma or value > options.max_luma then return nil end
    return value
end

local function raw_luma(sample, x, y)
    local r, g, b = sample.rgb(x, y)
    if r == nil then return nil end
    return luminance(r, g, b)
end

-- True when a pixel can be read as track: neutral, and darker than the thumb
-- window. A pixel that is neither track nor a thumb pixel (coloured, or
-- brighter than the accepted window) is unjudgeable rather than background.
function module.track_pixel(sample, x, y, options)
    local r, g, b = sample.rgb(x, y)
    if r == nil then return false end
    local high, low = r, r
    if g > high then high = g end
    if b > high then high = b end
    if g < low then low = g end
    if b < low then low = b end
    if high - low > options.max_spread then return false end
    return luminance(r, g, b) < options.min_luma
end

-- Coarse brightness of a capture, used to detect a black frame (a GDI capture
-- that never sees the rendered game, e.g. under an overlay plane).
function module.strip_luminance(sample)
    local step_x = math.max(1, math.floor(sample.width / 24))
    local step_y = math.max(1, math.floor(sample.height / 24))
    local total, count = 0, 0
    for y = 0, sample.height - 1, step_y do
        for x = 0, sample.width - 1, step_x do
            local value = raw_luma(sample, x, y)
            if value then
                total = total + value
                count = count + 1
            end
        end
    end
    if count == 0 then return nil end
    return total / count
end

-- Dark-quartile luminance of a capture, used to place the thumb threshold
-- relative to the frame the game actually produced. Bright menus are ignored
-- by taking a low quantile instead of the mean.
function module.background_luminance(sample, quantile)
    local step_x = math.max(1, math.floor(sample.width / 32))
    local step_y = math.max(1, math.floor(sample.height / 32))
    local histogram, total = {}, 0
    for y = 0, sample.height - 1, step_y do
        for x = 0, sample.width - 1, step_x do
            local value = raw_luma(sample, x, y)
            if value then
                local bucket = math.floor(value / 8)
                histogram[bucket] = (histogram[bucket] or 0) + 1
                total = total + 1
            end
        end
    end
    if total == 0 then return nil end
    local target = math.max(1, math.floor(total * (quantile or 0.25)))
    local seen = 0
    for bucket = 0, 31 do
        seen = seen + (histogram[bucket] or 0)
        if seen >= target then return bucket * 8 + 4 end
    end
    return 255
end

-- Per-capture copy of the settings with the thumb brightness window adapted to
-- the measured background, so a dim GDI capture of an HDR frame behaves like
-- the bright reference screenshots.
function module.adapt_options(sample, options)
    local background = module.background_luminance(sample)
    if background == nil then return options, nil end
    local tuned = {}
    for key, value in pairs(options) do tuned[key] = value end
    tuned.min_luma = math.max(options.min_luma_floor or 40, background + (options.min_contrast or 30))
    if tuned.min_luma > 240 then tuned.min_luma = 240 end
    return tuned, background
end

local function cursor_masked(cursor, mask, x, y)
    -- A missing or malformed cursor means "no mask": the detector then judges
    -- every pixel instead of raising, which keeps a caller mistake diagnostic
    -- rather than fatal.
    if not cursor or type(cursor.x) ~= 'number' or type(cursor.y) ~= 'number' then return false end
    if not mask or type(mask.x0) ~= 'number' then return false end
    return x >= cursor.x + mask.x0 and x <= cursor.x + mask.x1
        and y >= cursor.y + mask.y0 and y <= cursor.y + mask.y1
end

-- Cheap column probe: a thumb column must show at least two thumb rows and one
-- clearly darker row, which a wall of bright stripes cannot. Columns that pass
-- are scanned in full, so the result matches a full scan.
local function column_probe(sample, cursor, x, options)
    local step = options.probe_step or 0
    if step <= 1 then return true, true end
    local offset = options.local_offset or 16
    local grey, lightest, darkest = 0, nil, nil
    for y = 0, sample.height - 1, step do
        if not cursor_masked(cursor, options.cursor_mask, x, y) then
            local value = module.thumb_pixel(sample, x, y, options)
            if value then
                local accepted = value
                if options.local_contrast then
                    accepted = nil
                    local left, right = raw_luma(sample, x - offset, y), raw_luma(sample, x + offset, y)
                    if left or right then
                        local beside = ((left or right) + (right or left)) / 2
                        if value - beside >= options.min_contrast then accepted = value end
                    end
                end
                if accepted then
                    grey = grey + 1
                    if not lightest or accepted < lightest then lightest = accepted end
                else
                    local luma = raw_luma(sample, x, y)
                    if luma and (not darkest or luma < darkest) then darkest = luma end
                end
            else
                local luma = raw_luma(sample, x, y)
                if luma and (not darkest or luma < darkest) then darkest = luma end
            end
            local panel = darkest ~= nil and lightest ~= nil
                and darkest <= lightest - options.min_contrast
            if grey >= 2 and panel then return true, true end
        end
    end
    local panel = darkest ~= nil and lightest ~= nil
        and darkest <= lightest - options.min_contrast
    return false, panel
end

-- Every accepted vertical run in one column, bridging rows hidden by the cursor.
local function scan_column(sample, cursor, x, options)
    local runs, start, grey, filled, bridge, gap, last_grey = {}, nil, 0, 0, 0, 0, nil
        local run_masked = false
        local function close(ending)
            if not start then return end
            -- Masked or interrupted rows only count as part of the thumb when
            -- another thumb pixel follows them.
            filled = filled - gap
            ending = math.min(ending, (last_grey or start) + 1)
            local length = ending - start
            if length >= options.min_height and length <= sample.height * options.max_height_ratio
                and grey >= filled * options.min_fill then
                -- Clipped by the glow or the capture edge: the hidden part is inferred, not read.
                local clipped_top = cursor_masked(cursor, options.cursor_mask, x, start - 1)
                    or start <= 0
                local clipped_bottom = cursor_masked(cursor, options.cursor_mask, x, ending)
                    or ending >= sample.height
                runs[#runs + 1] = {top = start, bottom = ending - 1,
                                   clipped_top = clipped_top and true or false,
                                   clipped_bottom = clipped_bottom and true or false,
                                   -- Only a clipped end makes the extent
                                   -- untrustworthy; a hidden middle does not.
                                   masked = (clipped_top or clipped_bottom) and true or false}
            end
            start, grey, filled, bridge, gap, last_grey = nil, 0, 0, 0, 0, nil
            run_masked = false
        end
        for y = 0, sample.height - 1 do
            local covered = cursor_masked(cursor, options.cursor_mask, x, y)
            local value = covered and nil or module.thumb_pixel(sample, x, y, options)
            if value and options.local_contrast then
                -- Wide bright areas (panels, blurred background) must not
                -- look like a thumb: require clearly darker pixels beside
                -- the column at the same row.
                local offset = options.local_offset or 16
                local left, right = raw_luma(sample, x - offset, y), raw_luma(sample, x + offset, y)
                if not left and not right then
                    value = nil
                else
                    local beside = ((left or right) + (right or left)) / 2
                    if value - beside < options.min_contrast then value = nil end
                end
            end
            if not value and covered and not module.track_pixel(sample, x, y, options) then
                -- Hidden by the pointer, not missing: the run keeps going through it.
                if start then
                    bridge = bridge + 1
                    run_masked = true
                    if bridge > options.max_bridge then
                        start, grey, filled, bridge, gap, last_grey = nil, 0, 0, 0, 0, nil
                        run_masked = false
                    end
                end
            else
                bridge = 0
                if value then
                    if not start then start, grey, filled, gap = y, 0, 0, 0 end
                    grey, filled, gap, last_grey = grey + 1, filled + 1, 0, y
                elseif start then
                    gap = gap + 1
                    filled = filled + 1
                    if gap > options.max_gap then close(y - gap + 1) end
                end
            end
        end
    close(sample.height)
    return runs
end

-- Longest vertical grey run per column, bridging rows hidden by the cursor.
-- Columns that cannot hold a thumb anywhere are rejected by the cheap probe, so
-- a strip that is mostly panel costs a fraction of a full scan.
local function column_runs(sample, cursor, options)
    local columns = {}
    local candidates = {}
    for x = 0, sample.width - 1 do
        local candidate, panel = column_probe(sample, cursor, x, options)
        if candidate or panel then
            candidates[#candidates + 1] = {x = x, panel = panel and true or false}
        end
    end
    -- A bar is only ever accepted in the pointer's own column, so when a screen
    -- is covered in bar-like structures the columns nearest the pointer are the
    -- ones worth scanning. This bounds the scan work no matter what is on screen.
    local limit = (options.probe_max_columns or ((options.max_width or 28) + 8))
    if #candidates > limit then
        local cursor_x = cursor and cursor.x or math.floor(sample.width / 2)
        table.sort(candidates, function(a, b)
            if a.panel ~= b.panel then return a.panel end
            return math.abs(a.x - cursor_x) < math.abs(b.x - cursor_x)
        end)
        for index = #candidates, limit + 1, -1 do candidates[index] = nil end
    end
    for index = 1, #candidates do
        local x = candidates[index].x
        local runs = scan_column(sample, cursor, x, options)
        if #runs > 0 then columns[x] = runs end
    end
    return columns
end

local function overlaps(first, second)
    local top = math.max(first.top, second.top)
    local bottom = math.min(first.bottom, second.bottom)
    if bottom < top then return false end
    local shortest = math.min(first.bottom - first.top, second.bottom - second.top)
    if shortest <= 0 then return false end
    return (bottom - top) >= shortest * 0.6
end

-- A thumb is uniform along its length and clearly darker-edged on both sides.
-- Rows hidden by the cursor's glow are skipped rather than judged.
local function bar_quality(sample, bar, options, cursor)
    local height = bar.bottom - bar.top + 1
    local middle = math.floor((bar.left + bar.right) / 2)
    local values, count = {}, 0
    for y = bar.top, bar.bottom, 3 do
        local value = nil
        if not cursor_masked(cursor, options.cursor_mask, middle, y) then
            value = module.thumb_pixel(sample, middle, y, options)
        end
        if value then
            count = count + 1
            values[#values + 1] = value
        end
    end
    if count < 4 then return false, 'sparse' end
    table.sort(values)
    local median = values[math.floor((count + 1) / 2)]
    local near = 0
    for index = 1, #values do
        if math.abs(values[index] - median) <= options.max_variance then near = near + 1 end
    end
    if near < count * options.min_uniformity then return false, 'not_uniform' end
    local best = nil
    for y = bar.top + 4, bar.bottom - 4, 7 do
        if not cursor_masked(cursor, options.cursor_mask, middle, y) then
            local outside, sides = 0, 0
            for _, range in ipairs({{bar.left - 3, bar.left - 1}, {bar.right + 1, bar.right + 3}}) do
                local total, samples = 0, 0
                for x = range[1], range[2] do
                    local value = raw_luma(sample, x, y)
                    if value then
                        total = total + value
                        samples = samples + 1
                    end
                end
                if samples > 0 then
                    outside = outside + total / samples
                    sides = sides + 1
                end
            end
            if sides > 0 then
                local value = outside / sides
                if not best or value < best then best = value end
            end
        end
    end
    if best and best > median - options.edge_contrast then
        return false, 'no_edge'
    end
    return true, median, height
end

-- Merge per-column runs into candidate bars. `band`, when given, selects the
-- bar overlapping those strip-local x coordinates instead of the cursor.
function module.find_thumb(sample, cursor, options, band)
    local columns = column_runs(sample, cursor, options)
    local bars, current = {}, nil
    for x = 0, sample.width - 1 do
        local runs = columns[x]
        local best = nil
        if runs then
            -- The cursor glow can split one thumb into two runs inside the same
            -- column; when both parts face the gap, they are one bar.
            local merged = {}
            for index = 1, #runs do
                local run = runs[index]
                local previous = merged[#merged]
                if previous and previous.clipped_bottom and run.clipped_top
                    and (run.top - previous.bottom) <= options.max_bridge then
                    previous.bottom = run.bottom
                    previous.clipped_bottom = run.clipped_bottom
                    previous.masked = previous.clipped_top or previous.clipped_bottom
                else
                    merged[#merged + 1] = {top = run.top, bottom = run.bottom,
                                           clipped_top = run.clipped_top,
                                           clipped_bottom = run.clipped_bottom,
                                           masked = run.masked}
                end
            end
            for index = 1, #merged do
                local run = merged[index]
                if not best or (run.bottom - run.top) > (best.bottom - best.top) then best = run end
            end
        end
        if best then
            if current and current.right == x - 1 and overlaps(current, best) then
                current.right = x
                if best.masked then current.masked = true end
                if best.clipped_top then current.clipped_top = true end
                if best.clipped_bottom then current.clipped_bottom = true end
                if best.top < current.top then current.top = best.top end
                if best.bottom > current.bottom then current.bottom = best.bottom end
            else
                if current then bars[#bars + 1] = current end
                current = {left = x, right = x, top = best.top, bottom = best.bottom,
                           masked = best.masked or false,
                           clipped_top = best.clipped_top or false,
                           clipped_bottom = best.clipped_bottom or false}
            end
        elseif current then
            bars[#bars + 1] = current
            current = nil
        end
    end
    if current then bars[#bars + 1] = current end

    local chosen, chosen_distance = nil, nil
    for index = 1, #bars do
        local bar = bars[index]
        local width = bar.right - bar.left + 1
        local height = bar.bottom - bar.top + 1
        if width >= options.min_width and width <= options.max_width and height >= options.min_height then
            local good, median = bar_quality(sample, bar, options, cursor)
            if good then bar.median = median end
            if not good then bar = nil end
        else
            bar = nil
        end
        if bar then
            if band then
                local overlap = math.min(bar.right, band.right) - math.max(bar.left, band.left) + 1
                if overlap > 0 then
                    local distance = -overlap
                    if not chosen or distance < chosen_distance then
                        chosen, chosen_distance = bar, distance
                    end
                end
            else
                local gap = 0
                if cursor.x < bar.left then gap = bar.left - cursor.x
                elseif cursor.x > bar.right then gap = cursor.x - bar.right end
                if gap <= options.column_tolerance then
                    local distance = gap * 4 + math.abs(cursor.y - clamp(cursor.y, bar.top, bar.bottom))
                    if not chosen or distance < chosen_distance then
                        chosen, chosen_distance = bar, distance
                    end
                end
            end
        end
    end
    if not chosen then return nil, 'no_thumb', bars end
    return chosen, nil, bars
end

-- Which side of the bar holds the list: artwork, spine and groove sit on the
-- list's side, panel on the other. Returns 'left', 'right' or nil; it is recorded
-- in the log, where it tells a reader which way the list lies from the bar.
function module.content_side(sample, bar, options)
    local reach = math.min(44, math.max(8, options.strip_width or 96))
    -- The answer only has to separate panel from content, and the scan must not
    -- grow with a thumb that fills the capture.
    local stride = math.max(4, math.floor((bar.bottom - bar.top + 1) / 48))
    -- Structure, not brightness: the panel beside a bar carries its own gradient,
    -- so a column is content when it stands out from its neighbours, not when it
    -- is brighter than them.
    local function relief(from, to)
        local means = {}
        for x = from, to do
            local total, count = 0, 0
            for y = bar.top, bar.bottom, stride do
                local value = raw_luma(sample, x, y)
                if value then
                    total = total + value
                    count = count + 1
                end
            end
            means[#means + 1] = count > 0 and total / count or nil
        end
        local best = 0
        for index = 2, #means - 1 do
            local left, middle, right = means[index - 1], means[index], means[index + 1]
            if left and middle and right then
                local step = math.abs(middle - (left + right) / 2)
                if step > best then best = step end
            end
        end
        return best
    end
    local left = relief(math.max(0, bar.left - reach), bar.left - 2)
    local right = relief(bar.right + 2, math.min(sample.width - 1, bar.right + reach))
    if left > right + 12 then return 'left' end
    if right > left + 12 then return 'right' end
    return nil
end

-- 'thumb' for a press on the visible bar, 'track' for the invisible track beside
-- it, nil for list content. The direction comes from the tracked thumb.
function module.decide(bar, cursor, sample, options)
    if cursor.y >= bar.top - options.thumb_margin and cursor.y <= bar.bottom + options.thumb_margin then
        return 'thumb', 'thumb'
    end
    local r, g, b = sample.rgb(cursor.x, cursor.y)
    if r ~= nil then
        local value = luminance(r, g, b)
        local bar_value = module.thumb_pixel(sample, bar.left + math.floor((bar.right - bar.left) / 2),
                                             bar.top + 2, options)
            or options.min_luma
        if value > bar_value - options.click_contrast then
            return nil, 'click_not_on_track'
        end
    end
    return 'track', 'track'
end

function module.analyse(sample, cursor, options, band)
    -- A caller that cannot supply a cursor gets a reason instead of a raise:
    -- every decision below depends on knowing where the pointer is.
    if not cursor or type(cursor.x) ~= 'number' or type(cursor.y) ~= 'number' then
        return nil, 'no_cursor'
    end
    options, sample.background = module.adapt_options(sample, options)
    local bar, reason, candidates = module.find_thumb(sample, cursor, options, band)
    if not bar then return nil, reason, candidates end
    bar.side = module.content_side(sample, bar, options)
    local hit, why = module.decide(bar, cursor, sample, options)
    if not hit then return nil, why, bar end
    return {bar = bar, hit = hit}, why
end

-- --------------------------------------------------------------- settings

function module.parse_settings(text, base)
    local settings = {}
    for key, value in pairs(base or DEFAULTS) do settings[key] = value end
    -- Keys that came from the ini hold absolute device pixels and are never
    -- scaled: a value the user typed means exactly what it says.
    local overridden = {}
    if type(text) == 'string' then
        for line in text:gmatch('[^\r\n]+') do
            local key, value = line:match('^%s*([%a_]+)%s*=%s*([%-%d%.]+)%s*$')
            if key and DEFAULTS[key] ~= nil and type(DEFAULTS[key]) ~= 'table' then
                local number = tonumber(value)
                if number then
                    overridden[key] = true
                    if type(DEFAULTS[key]) == 'boolean' then
                        settings[key] = number ~= 0
                    else
                        settings[key] = number
                    end
                end
            end
        end
    end
    settings.overridden = overridden
    return module.clamp_settings(settings)
end

-- Bounds every value so a hostile or careless ini cannot produce a geometry the
-- detector or the capture surface cannot honour.
function module.clamp_settings(settings)
    settings.strip_width = clamp(math.floor(settings.strip_width), 32, 240)
    settings.window = clamp(math.floor(settings.window), 120, 1400)
    settings.window_max = clamp(math.floor(settings.window_max), settings.window, 1400)
    settings.narrow_width = clamp(math.floor(settings.narrow_width), 16, 120)
    settings.narrow_window = clamp(math.floor(settings.narrow_window), 120, 1400)
    settings.bar_cache_ms = clamp(math.floor(settings.bar_cache_ms), 0, 600000)
    settings.min_height = clamp(math.floor(settings.min_height), 12, 1200)
    settings.max_height_ratio = clamp(settings.max_height_ratio, 0.1, 1)
    settings.min_width = clamp(math.floor(settings.min_width), 3, 60)
    settings.max_width = clamp(math.floor(settings.max_width), settings.min_width, 80)
    settings.min_luma = clamp(math.floor(settings.min_luma), 30, 250)
    settings.max_luma = clamp(math.floor(settings.max_luma), settings.min_luma + 5, 255)
    settings.min_luma_floor = clamp(math.floor(settings.min_luma_floor), 10, 240)
    settings.min_contrast = clamp(math.floor(settings.min_contrast), 5, 200)
    settings.local_contrast = settings.local_contrast and true or false
    settings.local_offset = clamp(math.floor(settings.local_offset), 4, 200)
    settings.max_spread = clamp(math.floor(settings.max_spread), 2, 120)
    settings.min_fill = clamp(settings.min_fill, 0.2, 1)
    settings.max_bridge = clamp(math.floor(settings.max_bridge), 0, 400)
    settings.max_gap = clamp(math.floor(settings.max_gap), 0, 400)
    settings.max_variance = clamp(math.floor(settings.max_variance), 1, 120)
    settings.min_uniformity = clamp(settings.min_uniformity, 0.1, 1)
    settings.edge_contrast = clamp(math.floor(settings.edge_contrast), 0, 200)
    settings.thumb_margin = clamp(math.floor(settings.thumb_margin), 0, 200)
    settings.column_tolerance = clamp(math.floor(settings.column_tolerance), 0, 120)
    settings.click_contrast = clamp(math.floor(settings.click_contrast), 0, 200)
    settings.default_pixels_per_notch = clamp(settings.default_pixels_per_notch, 4, 400)
    settings.bar_reference_width = clamp(settings.bar_reference_width, 2, 60)
    settings.center_tolerance = clamp(math.floor(settings.center_tolerance), 0, 100)
    settings.jump_max_notches = clamp(math.floor(settings.jump_max_notches), 1, 2000)
    settings.emit_max_notches = clamp(math.floor(settings.emit_max_notches), 1, 2000)
    settings.correction_notches = clamp(math.floor(settings.correction_notches), 1, 200)
    settings.max_corrections = clamp(math.floor(settings.max_corrections), 0, 30)
    settings.settle_delay_ms = clamp(math.floor(settings.settle_delay_ms), 20, 5000)
    settings.settle_interval_ms = clamp(math.floor(settings.settle_interval_ms), 10, 2000)
    settings.settle_stable_px = clamp(settings.settle_stable_px, 0, 100)
    settings.settle_checks = clamp(math.floor(settings.settle_checks), 1, 50)
    settings.drag_threshold = clamp(math.floor(settings.drag_threshold), 2, 200)
    settings.drag_max_step_px = clamp(math.floor(settings.drag_max_step_px), 20, 2000)
    settings.drag_max_notches = clamp(math.floor(settings.drag_max_notches), 1, 400)
    settings.drag_column_margin = clamp(settings.drag_column_margin, 0.5, 40)
    settings.drag_verify_notches = clamp(math.floor(settings.drag_verify_notches), 1, 100)
    settings.drag_verify_ms = clamp(math.floor(settings.drag_verify_ms), 20, 5000)
    settings.drag_stall_confirmations = clamp(math.floor(settings.drag_stall_confirmations), 1, 10)
    settings.track_clamp_max_notches = clamp(math.floor(settings.track_clamp_max_notches), 0, 400)
    settings.native = clamp(math.floor(settings.native), 0, 1)
    settings.native_verify_ms = clamp(math.floor(settings.native_verify_ms), 20, 2000)
    settings.calibration_samples = clamp(math.floor(settings.calibration_samples), 1, 25)
    settings.calibration_min_px = clamp(settings.calibration_min_px, 1, 200)
    settings.calibration_max_px = clamp(settings.calibration_max_px, settings.calibration_min_px, 400)
    settings.trace_lines = clamp(math.floor(settings.trace_lines), 0, 500)
    settings.trace_events = clamp(math.floor(settings.trace_events), 0, 1)
    settings.log_interval_ms = clamp(math.floor(settings.log_interval_ms), 0, 60000)
    settings.cooldown_ms = clamp(math.floor(settings.cooldown_ms), 0, 5000)
    settings.min_capture_interval_ms = clamp(math.floor(settings.min_capture_interval_ms), 0, 5000)
    settings.use_window_capture = clamp(math.floor(settings.use_window_capture), 0, 1)
    settings.scale_geometry = clamp(math.floor(settings.scale_geometry), 0, 1)
    settings.probe_step = clamp(math.floor(settings.probe_step), 1, 64)
    settings.burst_cache_ms = clamp(math.floor(settings.burst_cache_ms), 0, 2000)
    settings.burst_capture_every = clamp(math.floor(settings.burst_capture_every), 1, 100)
    settings.capture_budget_ms_per_s = clamp(math.floor(settings.capture_budget_ms_per_s), 0, 5000)
    settings.capture_budget_floor_ms_per_s = clamp(math.floor(settings.capture_budget_floor_ms_per_s), 0, 5000)
    settings.error_limit = clamp(math.floor(settings.error_limit), 1, 1000)
    settings.dump_captures = clamp(math.floor(settings.dump_captures), 0, 50)
    settings.cursor_mask_radius = clamp(settings.cursor_mask_radius, 24, 320)
    settings.cursor_mask = {
        x0 = -math.floor(settings.cursor_mask_radius), x1 = math.ceil(settings.cursor_mask_radius),
        y0 = -math.floor(settings.cursor_mask_radius), y1 = math.ceil(settings.cursor_mask_radius),
    }
    settings.enabled = settings.enabled and true or false
    return settings
end

-- The reference geometry was measured on a 1440 px tall viewport, which the
-- interface was assumed to follow; the bar's measured thickness corrects that.
local REFERENCE_HEIGHT = 1440

function module.scale_for_height(height)
    if type(height) ~= 'number' or height < 240 then return 1 end
    return clamp(height / REFERENCE_HEIGHT, 0.4, 4)
end

function module.scale_settings(base, scale)
    local scaled = {}
    for key, value in pairs(base) do scaled[key] = value end
    scaled.scale = scale
    if scale == 1 then return module.clamp_settings(scaled) end
    for _, key in ipairs(DEFAULTS.scaled_keys) do
        if not (base.overridden and base.overridden[key]) then
            scaled[key] = base[key] * scale
        end
    end
    if not (base.overridden and base.overridden.cursor_mask_radius) then
        scaled.cursor_mask_radius = base.cursor_mask_radius * scale
    end
    return module.clamp_settings(scaled)
end

-- --------------------------------------------------------------- platform

function module.create_platform()
    local ffi = require('ffi')
    local bit = require('bit')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    ffi.cdef [[
        typedef struct { int x; int y; } HD2CS_POINT;
        typedef struct { int left; int top; int right; int bottom; } HD2CS_RECT;
        typedef struct {
            unsigned int biSize; int biWidth; int biHeight; unsigned short biPlanes;
            unsigned short biBitCount; unsigned int biCompression; unsigned int biSizeImage;
            int biXPelsPerMeter; int biYPelsPerMeter; unsigned int biClrUsed; unsigned int biClrImportant;
        } HD2CS_BITMAPINFOHEADER;
        typedef struct { HD2CS_BITMAPINFOHEADER bmiHeader; unsigned int bmiColors[3]; } HD2CS_BITMAPINFO;
        typedef struct {
            int dx; int dy; unsigned int mouseData; unsigned int dwFlags;
            unsigned int time; unsigned long long dwExtraInfo;
        } HD2CS_MOUSEINPUT;
        typedef struct { unsigned int type; unsigned int padding; HD2CS_MOUSEINPUT mi; } HD2CS_INPUT;
        int GetCursorPos(HD2CS_POINT *point);
        short GetAsyncKeyState(int key);
        void *GetForegroundWindow(void);
        void *GetDC(void *window);
        int ReleaseDC(void *window, void *dc);
        int GetSystemMetrics(int index);
        unsigned int GetCurrentProcessId(void);
        unsigned int GetWindowThreadProcessId(void *window, unsigned int *process);
        int GetClientRect(void *window, HD2CS_RECT *rect);
        int ClientToScreen(void *window, HD2CS_POINT *point);
        int IsWindow(void *window);
        unsigned int SendInput(unsigned int count, HD2CS_INPUT *inputs, int size);
        void *CreateCompatibleDC(void *dc);
        void *CreateDIBSection(void *dc, HD2CS_BITMAPINFO *info, unsigned int usage,
                               void **bits, void *section, unsigned int offset);
        void *SelectObject(void *dc, void *object);
        int BitBlt(void *dest, int x, int y, int width, int height, void *source,
                   int source_x, int source_y, unsigned int rop);
        int DeleteObject(void *object);
        int DeleteDC(void *dc);
        unsigned long long GetTickCount64(void);
    ]]
    local user32, gdi32, kernel32 = ffi.load('user32'), ffi.load('gdi32'), ffi.load('kernel32')

    -- LuaJIT resolves each imported symbol on first use, so every binding is
    -- exercised once here: a wrong library or a missing export must surface as
    -- a named startup error instead of failing on the first click.
    local function check(name, fn, ...)
        local ok, value = pcall(fn, ...)
        if not ok then error(name .. ': ' .. tostring(value), 0) end
        return value
    end
    check('GetTickCount64', function() return kernel32.GetTickCount64() end)
    local process_id = check('GetCurrentProcessId', function() return kernel32.GetCurrentProcessId() end)
    check('GetAsyncKeyState', function() return user32.GetAsyncKeyState(0) end)
    check('GetForegroundWindow', function() return user32.GetForegroundWindow() end)
    check('GetSystemMetrics', function() return user32.GetSystemMetrics(0) end)
    -- Indexing a loaded library resolves the symbol, so a missing export still
    -- surfaces at startup - without calling it with a null window handle.
    for _, name in ipairs({'IsWindow', 'GetClientRect', 'ClientToScreen'}) do
        if user32[name] == nil then error('user32.' .. name .. ' unavailable', 0) end
    end
    local screen_dc = check('GetDC', function() return user32.GetDC(nil) end)
    assert(screen_dc ~= nil, 'Screen device context unavailable')
    local memory_dc = check('CreateCompatibleDC', function() return gdi32.CreateCompatibleDC(screen_dc) end)
    assert(memory_dc ~= nil, 'Memory device context unavailable')
    local SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN = 76, 77
    local SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 78, 79
    local virtual = {
        x = user32.GetSystemMetrics(SM_XVIRTUALSCREEN),
        y = user32.GetSystemMetrics(SM_YVIRTUALSCREEN),
        width = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN),
        height = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN),
    }
    local dib_width = 240
    local dib_height = clamp(virtual.height, 480, 4320)
    local info = ffi.new('HD2CS_BITMAPINFO')
    info.bmiHeader.biSize = ffi.sizeof('HD2CS_BITMAPINFOHEADER')
    info.bmiHeader.biWidth = dib_width
    info.bmiHeader.biHeight = -dib_height -- top-down rows
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    info.bmiHeader.biCompression = 0
    local bits = ffi.new('void *[1]')
    local bitmap = check('CreateDIBSection', function()
        return gdi32.CreateDIBSection(screen_dc, info, 0, bits, nil, 0)
    end)
    assert(bitmap ~= nil and bits[0] ~= nil, 'Capture bitmap unavailable')
    check('SelectObject', function() return gdi32.SelectObject(memory_dc, bitmap) end)
    local pixels = ffi.cast('unsigned char *', bits[0])
    local point = ffi.new('HD2CS_POINT[1]')
    local input = ffi.new('HD2CS_INPUT[1]')
    local input_size = ffi.sizeof('HD2CS_INPUT')
    -- Declared later, a shared scratch buffer is a global inside the function and
    -- indexing it raises (the v2.2 "attempt to index global 'rect'" crash).
    local rect, client_origin = ffi.new('HD2CS_RECT[1]'), ffi.new('HD2CS_POINT[1]')
    input[0].type = 0
    input[0].mi.dwFlags = 0x0800 -- MOUSEEVENTF_WHEEL

    local platform = {}

    check('GetCursorPos', function() return user32.GetCursorPos(point) end)

    function platform.now()
        return tonumber(kernel32.GetTickCount64())
    end

    function platform.cursor()
        if user32.GetCursorPos(point) == 0 then return nil end
        return point[0].x, point[0].y
    end

    -- Height of the game's own viewport, read in the same coordinate space as the
    -- cursor. The interface does not follow it exactly; the bar's measured
    -- thickness is the better scale.
    function platform.display_height()
        local window = user32.GetForegroundWindow()
        if window ~= nil and user32.IsWindow(window) ~= 0 and user32.GetClientRect(window, rect) ~= 0 then
            local height = rect[0].bottom - rect[0].top
            if height >= 240 then return height end
        end
        if virtual.height >= 240 then return virtual.height end
        return nil
    end

    function platform.viewport()
        local window = user32.GetForegroundWindow()
        if window == nil or user32.GetClientRect(window, rect) == 0 then return nil end
        client_origin[0].x, client_origin[0].y = 0, 0
        if user32.ClientToScreen(window, client_origin) == 0 then return nil end
        return {x = tonumber(client_origin[0].x), y = tonumber(client_origin[0].y),
                width = tonumber(rect[0].right), height = tonumber(rect[0].bottom)}
    end

    function platform.pressed()
        return bit.band(user32.GetAsyncKeyState(0x01), 0x8000) ~= 0
    end


    -- Raw two-byte GetAsyncKeyState value for VK_LBUTTON, for diagnostics
    -- (0x8000 = down now, 0x0001 = pressed since the previous query).
    function platform.key_state()
        local value = user32.GetAsyncKeyState(0x01)
        if value < 0 then value = value + 65536 end
        return value
    end

    function platform.foreground_self()
        local window = user32.GetForegroundWindow()
        if window == nil then return false end
        local owner = ffi.new('unsigned int[1]')
        user32.GetWindowThreadProcessId(window, owner)
        return owner[0] == process_id
    end

    -- The window DC is far cheaper than the desktop DC but can answer black or stale,
    -- so the first capture validates it.
    local window_handle, window_dc = nil, nil

    local function window_source()
        local window = user32.GetForegroundWindow()
        if window == nil or user32.IsWindow(window) == 0 then return nil end
        if window ~= window_handle then
            if window_dc ~= nil and window_handle ~= nil then user32.ReleaseDC(window_handle, window_dc) end
            window_handle, window_dc = window, user32.GetDC(window)
        end
        if window_dc == nil then return nil end
        if user32.GetClientRect(window_handle, rect) == 0 then return nil end
        client_origin[0].x, client_origin[0].y = 0, 0
        if user32.ClientToScreen(window_handle, client_origin) == 0 then return nil end
        return window_dc, client_origin[0].x, client_origin[0].y, rect[0].right, rect[0].bottom
    end

    function platform.capture(center_x, center_y, options, strip_width, strip_window, source)
        if virtual.width < 8 or virtual.height < 8 then return nil end
        local width = math.min(math.floor(strip_width or options.strip_width), dib_width, virtual.width)
        local height = math.min(math.floor(strip_window or options.window) * 2, dib_height, virtual.height)
        local origin_x = clamp(math.floor(center_x - width / 2), virtual.x, virtual.x + virtual.width - width)
        local origin_y = clamp(math.floor(center_y - height / 2), virtual.y, virtual.y + virtual.height - height)
        if width < 8 or height < 16 then return nil end
        local device, source_x, source_y = screen_dc, origin_x, origin_y
        if source == 'window' then
            local dc, client_x, client_y, client_width, client_height = window_source()
            if dc == nil then return nil end
            local local_x, local_y = origin_x - client_x, origin_y - client_y
            -- Anything outside the client area is not ours to copy.
            if local_x < 0 or local_y < 0 or local_x + width > client_width
                or local_y + height > client_height then
                return nil
            end
            device, source_x, source_y = dc, local_x, local_y
        end
        local copied = gdi32.BitBlt(memory_dc, 0, 0, width, height, device, source_x, source_y,
                                   0x00CC0020 + 0x40000000) -- SRCCOPY | CAPTUREBLT
        if copied == 0 then return nil end
        -- The DIB keeps its allocated width, so rows must be read with the
        -- bitmap stride, not the captured strip width.
        local stride = dib_width * 4
        local sample = {width = width, height = height, stride = stride,
                        origin_x = origin_x, origin_y = origin_y}
        function sample.rgb(x, y)
            if x < 0 or y < 0 or x >= width or y >= height then return nil end
            local offset = y * stride + x * 4
            return pixels[offset + 2], pixels[offset + 1], pixels[offset]
        end
        return sample
    end

    -- Raw 32-bit BMP of a capture, for diagnosing what the detector sees.
    function platform.dump(sample, path)
        local width, height, stride = sample.width, sample.height, sample.stride
        local row_bytes = width * 4
        local file = io.open(path, 'wb')
        if not file then return false end
        local function u16(value) return string.char(value % 256, math.floor(value / 256) % 256) end
        local function u32(value)
            return string.char(value % 256, math.floor(value / 256) % 256,
                               math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
        end
        local size = 54 + row_bytes * height
        file:write('BM', u32(size), u32(0), u32(54), u32(40), u32(width), u32(height),
                   u16(1), u16(32), u32(0), u32(row_bytes * height), u32(2835), u32(2835), u32(0), u32(0))
        for y = height - 1, 0, -1 do
            file:write(ffi.string(pixels + y * stride, row_bytes))
        end
        file:close()
        return true
    end

    function platform.wheel(notches)
        input[0].mi.mouseData = notches * 120
        return user32.SendInput(1, input, input_size) == 1
    end

    function platform.close()
        if window_dc ~= nil and window_handle ~= nil then user32.ReleaseDC(window_handle, window_dc) end
        window_dc, window_handle = nil, nil
        if bitmap ~= nil then gdi32.DeleteObject(bitmap) end
        if memory_dc ~= nil then gdi32.DeleteDC(memory_dc) end
        if screen_dc ~= nil then user32.ReleaseDC(nil, screen_dc) end
        bitmap, memory_dc, screen_dc = nil, nil, nil
    end

    return platform
end

-- ------------------------------------------------------------------ install

function module.install(create_platform, environment)
    local environment = environment or _G
    local loader = rawget(environment, 'CowboyBingusModLoader')
    if type(loader) ~= 'table' or (loader.api or 0) < 1 then
        return nil, 'Bingus Shared Loader API 1 is required'
    end
    if rawget(environment, 'ClickableScrollbars') then
        return nil, 'already installed'
    end
    if type(environment.update) ~= 'function' then
        return nil, 'game update callback unavailable'
    end

    local state = {
        revision = module.revision, status = 'starting', settings = module.parse_settings(nil, DEFAULTS),
        clicks = 0, pages = 0, drags = 0, corrections = 0, no_response = 0, misses = 0, skipped = 0,
        capture_failures = 0, errors = 0, frames = 0, down_frames = 0, frame_clicks = 0, last_key = 0,
        wheel_units = 0, drag_notches = 0, drag_active = false,
        captures = 0, dumps = 0, last_dump = nil,
        wide_retries = 0, capture_fallbacks = 0,
        geometry_failures = 0, geometry_failed = false,
        emit_clamps = 0,
        settle_budget_skips = 0, frame_interval_ms = nil, effective_budget_ms_per_s = nil,
        drag_verifies = 0, drag_stalls = 0, drag_limits = 0, drag_out = 0, drag_rejects = 0,
        drag_resyncs = 0,
        track_top = nil, track_bottom = nil, track_column = nil, track_blocked = 0,
        track_drops = 0, drag_foreground_pauses = 0,
        burst_skips = 0, budget_skips = 0, capture_window_start = nil, capture_window_ms = 0,
        frame_ms_total = 0, frame_ms_max = 0, capture_ms_total = 0, capture_ms_max = 0,
        dirty = true, last_reason = 'start', last_direction = nil, last_bar = nil, last_notches = 0,
        last_delta = nil, last_moved = nil, last_luminance = nil, last_background = nil,
        last_click_luma = nil, last_bar_luma = nil,
        last_thumb_masked = nil, bar_cache = nil, last_error = nil,
        pixels_per_notch = nil, calibration = {},
    }
    rawset(environment, 'ClickableScrollbars', state)

    local function read_settings()
        local base = os.getenv('LOCALAPPDATA')
        if not base then return state.settings end
        local path = base .. '/ClickableScrollbars'
        local file = io.open(path .. '/ClickableScrollbars.ini', 'rb')
        if not file then return state.settings end
        local text = file:read(4096)
        file:close()
        return module.parse_settings(text, DEFAULTS)
    end

    local created, platform = pcall(create_platform)
    if not created then
        state.status = 'disabled: ' .. tostring(platform)
        return nil, state.status
    end

    -- The UI bridge, if the loader hands this addon its API factory. It is what the
    -- new architecture drives; without it the addon does not synthesise a drag at all,
    -- because a synthesised one cannot avoid pressing whatever the pointer crosses.
    local factory = environment.create_api or (loader and loader.create_api)
    state.bridge, state.bridge_reason = module.ui_bridge(factory)
    -- The native route needs only a reader: the addon builds that itself with the
    -- same FFI surface the shipped Armory mods use, and the loader may hand one in.
    -- The armory grid exists only while its screen does, so this first attempt is
    -- for the log; the press path retries through refresh_native.
    if state.bridge and state.bridge.api then
        state.native_api = state.bridge.api
    else
        local ok, api, reason = pcall(module.native_api)
        if ok and type(api) == 'table' then
            state.native_api = api
        else
            state.native_reason = tostring(reason or api)
        end
    end
    state.native_api_attempted = true
    if state.native_api then
        state.native, state.native_reason = module.native_locate(state.native_api)
        state.native_try = platform.now()
        if state.native then
            state.native_model, state.native_state_reason = module.native_state(state.native)
        end
    end
    -- The ini is read once and kept as the base; the effective settings are the
    -- base at the current display scale, so a resolution change can be followed
    -- without re-reading anything.
    state.base_settings = read_settings()
    state.settings = state.base_settings
    state.status = state.settings.enabled and 'running' or 'disabled: config'

    local previous_update, previous_shutdown = environment.update, environment.shutdown
    local last_button, last_capture_ms = false, -100000
    local last_frame_ms, last_log_ms = -1, -100000
    local last_observe_ms, last_jump_ms = -100000, -100000
    local stopped = false
    local drag, thumb, jump = nil, nil, nil
    -- Input capture outlives a cancelled scroll until the physical mouse-up.
    -- Releasing over another control must not turn the old hold into a click.
    local settings_capture
    -- Notches sent since `thumb.observed_at`, so a later observation can turn
    -- the movement the game produced into a pixels-per-notch sample.
    local injected_total = 0
    local trace, reason_counts = {}, {}
    local function note(reason)
        state.last_reason = reason
        state.dirty = true
        reason_counts[reason] = (reason_counts[reason] or 0) + 1
    end

    -- The log is the flight recorder: settings, counters, health, geometry,
    -- calibration, reason tally, trace. Rewritten, never grown.
    local function log(force)
        local now = platform.now()
        if not force then
            if state.settings.diagnostics ~= 1 then return end
            if not state.dirty then return end
            if now - last_log_ms < state.settings.log_interval_ms then return end
        end
        last_log_ms, state.dirty = now, false
        pcall(function()
            local file = loader.open_log and loader.open_log('ClickableScrollbars.log')
            if not file then return end
            local out = {}
            local function put(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
            put('%s', state.revision)
            put('status=%s', state.status)
            if state.last_error then put('error=%s', state.last_error) end
            put('--- settings')
            put('scale=%s', tostring(state.scale or 1))
            put('display_height=%s', tostring(state.display_height or 'unknown'))
            for _, key in ipairs({'enabled', 'center_tolerance', 'jump_max_notches', 'correction_notches',
                                  'max_corrections', 'settle_delay_ms', 'settle_interval_ms', 'settle_stable_px',
                                  'settle_checks', 'drag_threshold', 'drag_max_step_px', 'drag_max_notches',
                                  'calibration_samples', 'calibration_min_px', 'calibration_max_px',
                                  'cooldown_ms', 'min_capture_interval_ms', 'log_interval_ms', 'trace_lines',
                                  'trace_events', 'use_window_capture', 'error_limit', 'dump_captures',
                                  'strip_width', 'window', 'narrow_width',
                                  'narrow_window', 'min_height', 'min_width', 'max_width', 'min_luma', 'max_luma',
                                  'min_contrast', 'click_contrast', 'thumb_margin', 'column_tolerance',
                                  'bar_cache_ms', 'window_max', 'probe_step', 'burst_cache_ms',
                                  'burst_capture_every', 'capture_budget_ms_per_s', 'scale_geometry',
                                  'cursor_mask_radius', 'emit_max_notches',
                                  'capture_budget_floor_ms_per_s',
                                  'drag_column_margin',
                                  'drag_verify_notches', 'drag_verify_ms', 'drag_stall_confirmations',
                                  'native', 'native_verify_ms'}) do
                put('%s=%s', key, tostring(state.settings[key]))
            end
            put('--- counters')
            for _, key in ipairs({'clicks', 'pages', 'drags', 'corrections', 'no_response', 'misses', 'skipped',
                                  'capture_failures', 'errors', 'frames', 'down_frames', 'frame_clicks',
                                  'wheel_units', 'drag_notches', 'burst_skips', 'budget_skips',
                                  'emit_clamps', 'settle_budget_skips', 'drag_verifies', 'drag_stalls',
                                  'drag_limits', 'drag_out', 'drag_rejects', 'mask_retries', 'track_drops',
                                  'drag_foreground_pauses', 'settle_unfocused', 'drag_resyncs',
                                  'native_writes', 'native_ok', 'native_fallbacks'}) do
                put('%s=%d', key, state[key] or 0)
            end
            put('--- health')
            put('capture_source=%s', tostring(state.capture_source or 'window'))
            put('capture_fallbacks=%d', state.capture_fallbacks or 0)
            put('wide_retries=%d', state.wide_retries or 0)
            put('geometry_failures=%d', state.geometry_failures or 0)
            put('capture_ms_per_s=%d', state.capture_window_ms or 0)
            put('capture_share_pct=%.1f', (state.capture_window_ms or 0) / 10)
            put('budget_effective=%s', tostring(math.floor(state.effective_budget_ms_per_s
                or state.settings.capture_budget_ms_per_s)))
            put('game_fps=%s', state.frame_interval_ms and string.format('%.0f', 1000 / state.frame_interval_ms)
                or 'unknown')
            put('captures=%d', state.captures)
            put('capture_ms_max=%d', state.capture_ms_max)
            put('capture_ms_avg=%.3f', state.captures > 0 and state.capture_ms_total / state.captures or 0)
            put('frame_ms_max=%d', state.frame_ms_max)
            put('frame_ms_avg=%.4f', state.frames > 0 and state.frame_ms_total / state.frames or 0)
            put('--- state')
            put('drag_active=%s', tostring(state.drag_active or false))
            put('jump_active=%s', tostring(jump ~= nil))
            put('injected_since_observe=%d', injected_total - (thumb and thumb.injected_at or injected_total))
            put('last_reason=%s', tostring(state.last_reason))
            put('last_direction=%s', tostring(state.last_direction or 'none'))
            put('last_notches=%d', state.last_notches or 0)
            put('last_delta=%s', tostring(state.last_delta or 'none'))
            put('last_moved=%s', tostring(state.last_moved or 'none'))
            put('pixels_per_notch=%s', state.pixels_per_notch and string.format('%.2f', state.pixels_per_notch)
                or 'none')
            local samples = {}
            for index = 1, #state.calibration do samples[index] = string.format('%.2f', state.calibration[index]) end
            put('calibration=%s', #samples > 0 and table.concat(samples, ',') or 'none')
            local bar = state.last_bar
            put('last_bar=%s', bar and (bar.left .. ',' .. bar.top .. ',' .. bar.right .. ',' .. bar.bottom)
                or 'none')
            put('last_bar_masked=%s', tostring(state.last_thumb_masked or false))
            local cache = state.bar_cache
            put('bar_cache=%s', cache and (cache.left .. ',' .. cache.right) or 'none')
            local tracked = thumb
            put('thumb=%s', tracked and string.format('%d..%d centre=%.1f height=%s', tracked.left, tracked.right,
                tracked.center_y, tostring(tracked.height)) or 'none')
            put('track_top=%s', state.track_top and string.format('%.1f', state.track_top) or 'none')
            put('track_bottom=%s', state.track_bottom and string.format('%.1f', state.track_bottom) or 'none')
            put('drag_held=%s', drag and (drag.held_units == 1 and 'up' or (drag.held_units == -1 and 'down'
                or 'none')) or 'none')
            -- The measured interface ruler: the bar's thickness against its
            -- reference thickness on the machine the constants were measured on.
            put('ui_ruler=%s', state.ruler and string.format('%.3f', state.ruler) or 'none')
            put('ui_bridge=%s', state.bridge and string.format('ui=%s dispatch=%s', tostring(state.bridge.ui),
                tostring(state.bridge.dispatch)) or ('none (' .. tostring(state.bridge_reason) .. ')'))
            if state.native then
                local model = state.native_model
                put('native grid=%s state=%s', tostring(state.native.key or 'resolved'),
                    state.native_failed and 'retired' or 'active')
                put('native model value=%s scroll=%s span=%s content=%s viewport=%s'
                    .. ' first=%s last=%s anchor=%s items=%s rows=%s columns=%s',
                    model and string.format('%.4f', model.value) or 'none',
                    model and string.format('%.1f', model.scroll or -1) or 'none',
                    model and string.format('%.1f', model.span) or 'none',
                    model and string.format('%.1f', model.content) or 'none',
                    model and string.format('%.1f', model.viewport) or 'none',
                    tostring(model and model.first), tostring(model and model.last),
                    tostring(model and model.anchor),
                    tostring(model and model.items), tostring(model and model.rows),
                    tostring(model and model.columns))
                put('native last_value=%s track=%s', state.native_value and string.format('%.4f', state.native_value)
                    or 'none', tostring(state.native_state_reason or 'read'))
            else
                put('native none (%s)', tostring(state.native_reason))
            end
            put('last_luminance=%s', tostring(state.last_luminance or 'none'))
            put('last_click_luma=%s', state.last_click_luma and string.format('%.1f', state.last_click_luma)
                or 'none')
            put('last_bar_luma=%s', state.last_bar_luma and string.format('%.1f', state.last_bar_luma) or 'none')
            put('background_luma=%s', tostring(state.last_background or 'none'))
            put('last_dump=%s', tostring(state.last_dump or 'none'))
            local names = {}
            for name in pairs(reason_counts) do names[#names + 1] = name end
            table.sort(names)
            local summary = {}
            for _, name in ipairs(names) do
                summary[#summary + 1] = name .. '=' .. reason_counts[name]
            end
            put('reason_counts=%s', #summary > 0 and table.concat(summary, ',') or 'none')
            put('--- trace')
            put('trace_lines=%d', #trace)
            for _, line in ipairs(trace) do put('trace %s', line) end
            file:write(table.concat(out, '\n') .. '\n')
            file:close()
        end)
    end

    local function per_notch()
        -- Follows the measured bar, not the display guess: both were identical across two
        -- client heights, while the guess would have scaled the step by 1.44.
        local ruler = state.ruler or 1
        return state.pixels_per_notch or state.settings.default_pixels_per_notch * ruler
    end

    local function record(fmt, ...)
        if state.settings.diagnostics ~= 1 then return end
        local line = select('#', ...) > 0 and string.format(fmt, ...) or fmt
        trace[#trace + 1] = string.format('%d %s', math.floor(platform.now()), line)
        while #trace > state.settings.trace_lines do table.remove(trace, 1) end
        state.dirty = true
    end

    -- The median of the recent observations, so one bad measurement (a clamped
    -- list end, a half-hidden thumb) cannot bias the step the pointer uses.
    local function push_calibration(value)
        state.calibration[#state.calibration + 1] = value
        while #state.calibration > state.settings.calibration_samples do
            table.remove(state.calibration, 1)
        end
        local sorted = {}
        for index = 1, #state.calibration do sorted[index] = state.calibration[index] end
        table.sort(sorted)
        state.pixels_per_notch = sorted[math.floor((#sorted + 1) / 2)]
    end

    -- All wheel paths share the same target check. Held input can only be sent
    -- inside the scrollbar itself; a pending click/correction remains tied to
    -- its original pointer position. Never deliver it to a newly hovered widget.
    local function wheel_target_valid()
        if not state.settings.enabled or not platform.foreground_self() then return false end
        local x, y = platform.cursor()
        if not x or not y then return false end
        if drag then
            if not platform.pressed() or not thumb then return false end
            local top = drag.track_top or state.track_top or (thumb.observed_y - thumb.height / 2)
            local bottom = drag.track_bottom or state.track_bottom or (thumb.observed_y + thumb.height / 2)
            return x >= drag.column_left and x <= drag.column_right and y >= top and y <= bottom
        end
        local target = state.wheel_target
        return not platform.pressed() and target
            and math.abs(x - target.x) <= state.settings.drag_threshold
            and math.abs(y - target.y) <= state.settings.drag_threshold
    end

    -- One notch, one wheel event, sent now, up to emit_max_notches per frame; the
    -- rest of a larger burst is carried into the next frames so no single frame can
    -- flood the game's input queue.
    local function emit(units)
        if not units or units == 0 then return 0 end
        if not wheel_target_valid() then
            state.pending_units = nil
            return 0
        end
        local ceiling = state.settings.emit_max_notches
        if ceiling and math.abs(units) > ceiling then
            -- A drag must never leave wheel input to run after release.
            if not drag then
                state.pending_units = (state.pending_units or 0) + units - (units > 0 and ceiling or -ceiling)
            end
            state.emit_clamps = (state.emit_clamps or 0) + 1
            record('emit spread %d over the next frames (%d now)', units, ceiling)
            units = units > 0 and ceiling or -ceiling
        end
        local step = units > 0 and 1 or -1
        local sent = 0
        for _ = 1, math.abs(units) do
            if not wheel_target_valid() or not platform.wheel(step) then break end
            sent = sent + step
        end
        injected_total = injected_total + sent
        state.wheel_units = (state.wheel_units or 0) + sent
        state.last_notches = sent
        if thumb then
            thumb.center_y = thumb.observed_y - (injected_total - thumb.injected_at) * per_notch()
        end
        if state.settings.trace_events == 1 then
            record('emit units=%d predicted=%s', sent, thumb and string.format('%.1f', thumb.center_y) or 'none')
        end
        return sent
    end

    -- Carried-over notches go out on later frames, and only while no button is held:
    -- a notch that arrives during a press is read by the game as a press on whatever
    -- the pointer has reached.
    local function flush_pending()
        local pending = state.pending_units
        if not pending or pending == 0 then return end
        state.pending_units = nil
        emit(pending)
    end

    -- Captures are the expensive part (a GDI blit plus a pixel scan), so they
    -- run only when a decision needs one and their cost is measured for the log.
    local function raw_capture(center_x, center_y, options, width, height, source)
        local started = platform.now()
        local sample = platform.capture(center_x, center_y, options, width, height, source)
        local elapsed = platform.now() - started
        state.captures = state.captures + 1
        state.capture_ms_total = state.capture_ms_total + elapsed
        if elapsed > state.capture_ms_max then state.capture_ms_max = elapsed end
        if state.capture_window_start == nil or started - state.capture_window_start >= 1000 then
            state.capture_window_start, state.capture_window_ms = started, 0
        end
        state.capture_window_ms = state.capture_window_ms + elapsed
        return sample
    end

    -- The budget is a share of frame time, not a capture count, with a floor so the
    -- feature never stops answering.
    local function refresh_budget()
        local configured = state.settings.capture_budget_ms_per_s
        if configured <= 0 then
            state.effective_budget_ms_per_s = 0
            return
        end
        local interval = state.frame_interval_ms
        local budget = configured
        if interval and interval > 20 then
            budget = configured * (20 / interval)
        end
        budget = math.max(state.settings.capture_budget_floor_ms_per_s, budget)
        if budget > configured then budget = configured end
        state.effective_budget_ms_per_s = budget
    end

    -- One question asked by both a press and a settle: may the addon spend a
    -- capture right now? A fresh window always allows one, so the feature cannot
    -- lock itself out.
    local function budget_available(now)
        local budget = state.effective_budget_ms_per_s
        if budget == nil then
            refresh_budget()
            budget = state.effective_budget_ms_per_s
        end
        if budget <= 0 then return true end
        if state.capture_window_start == nil or now - state.capture_window_start >= 1000 then return true end
        local estimate = math.max(state.capture_ms_total / math.max(state.captures, 1), 4)
        return (state.capture_window_ms or 0) + estimate <= budget
    end

    -- The game clamping the thumb is the only signal of where the list begins: the
    -- pixels above the list are the same panel. Knowing the ends stops a drag from
    -- spending notches on wheel events that go to whatever the pointer reached.
    local function learn_track_bound(direction, centre, height)
        if not centre or not height then return end
        state.track_column = state.track_column or (thumb and thumb.left)
        if direction == 'top' then
            local top = centre - height / 2
            if not state.track_top or top < state.track_top then state.track_top = top end
        else
            local bottom = centre + height / 2
            if not state.track_bottom or bottom > state.track_bottom then state.track_bottom = bottom end
        end
        record('track bound %s top=%s bottom=%s', direction, tostring(state.track_top),
               tostring(state.track_bottom))
    end

    -- A learned end is a hint: bounded by track_clamp_max_notches notches of dragging
    -- and dropped by any observation that contradicts it.
    local function drop_track_bounds(reason)
        if state.track_top or state.track_bottom then
            state.track_drops = (state.track_drops or 0) + 1
            record('track bounds dropped (%s) top=%s bottom=%s', reason, tostring(state.track_top),
                   tostring(state.track_bottom))
        end
        state.track_top, state.track_bottom, state.track_blocked = nil, nil, 0
    end

    local function check_track_bounds(centre, height)
        if not centre or not height then return end
        if state.track_top and centre - height / 2 < state.track_top - 2 then
            drop_track_bounds('thumb above the learned top')
        elseif state.track_bottom and centre + height / 2 > state.track_bottom + 2 then
            drop_track_bounds('thumb below the learned bottom')
        end
    end

    -- Geometry follows the display height and is re-derived whenever it changes, so a
    -- monitor or resolution change is picked up on the next press.
    local function refresh_geometry(force)
        -- A display query must never be able to stop the addon: a driver or
        -- Windows quirk here costs the scale, not the feature. The failure is
        -- counted and logged once per state change.
        local height = nil
        if platform.display_height then
            local ok, value = pcall(platform.display_height)
            if ok then
                height = value
                if state.geometry_failed then
                    state.geometry_failed = false
                    record('display query recovered after %d failures', state.geometry_failures or 0)
                end
            else
                state.geometry_failures = (state.geometry_failures or 0) + 1
                if not state.geometry_failed then
                    state.geometry_failed = true
                    record('display query failed: %s', tostring(value))
                end
            end
        end
        if not height then return false end
        local guess = state.settings.scale_geometry == 1 and module.scale_for_height(height) or 1
        -- The display height is only a guess: the bar's measured thickness corrects it
        -- within a factor of two, while the display it was measured on is unchanged.
        -- The measurement may correct the guess downwards, never upwards: a larger
        -- capture window sees more of the screen, and a false bar-like run of the
        -- wrong thickness must not be able to widen it.
        local ruler = state.ruler
        if ruler and state.ruler_height and math.abs(state.ruler_height - height) > 0.02 * height then
            ruler, state.ruler = nil, nil
        end
        local scale = ruler and math.min(guess, clamp(ruler, guess / 2, guess * 2)) or guess
        if not force and state.scale and math.abs(scale - state.scale) <= 0.02 * state.scale then return false end
        local first = state.scale == nil
        local moved_display = state.display_height ~= nil and math.abs(state.display_height - height) > 0.02 * height
        state.display_height, state.scale = height, scale
        state.settings = module.scale_settings(state.base_settings, scale)
        if not first then
            state.bar_cache, state.thumb_height, state.pixels_per_notch = nil, nil, nil
            state.calibration = {}
            if moved_display then state.ruler = nil end
            record('geometry changed scale=%.3f height=%d window=%d strip=%d mask=%d step=%.1f', scale, height,
                   state.settings.window, state.settings.strip_width, state.settings.cursor_mask_radius,
                   state.settings.default_pixels_per_notch)
            state.dirty = true
        end
        return true
    end

    -- The window DC is cheaper but can answer black or stale for a flip-model swap
    -- chain, so the first capture compares both before choosing.
    local function timed_capture(center_x, center_y, options, width, height)
        local source = state.settings.use_window_capture == 1 and (state.capture_source or 'window') or 'screen'
        local sample = raw_capture(center_x, center_y, options, width, height, source)
        if source == 'screen' then
            state.capture_source = 'screen'
            return sample
        end
        local average = sample and module.strip_luminance(sample)
        if sample then sample.average = average end
        local usable = sample ~= nil and average ~= nil and average >= 6
        if usable and not state.capture_validated then
            local reference = raw_capture(center_x, center_y, options, width, height, 'screen')
            local reference_average = reference and module.strip_luminance(reference)
            state.capture_validated = true
            usable = reference ~= nil and reference_average ~= nil
                and math.abs(reference_average - average) <= 20
            record('capture window %s window=%s screen=%s', usable and 'kept' or 'rejected',
                   tostring(average), tostring(reference_average))
            if not usable then sample = reference end
        end
        if usable then
            state.capture_source = 'window'
            return sample
        end
        state.capture_fallbacks = (state.capture_fallbacks or 0) + 1
        state.capture_source = 'screen'
        record('capture window unusable (%s); using the desktop DC', tostring(average))
        if sample == nil then sample = raw_capture(center_x, center_y, options, width, height, 'screen') end
        return sample
    end

    -- One analysis pass: brightness sanity, optional dump, detect.
    local function analysis_for(sample, cursor_x, cursor_y, band)
        local average = sample.average
        if average == nil then
            average = module.strip_luminance(sample)
            sample.average = average
        end
        state.last_luminance = average
        if average ~= nil and average < 6 then
            state.capture_failures = state.capture_failures + 1
            return nil, 'capture_black'
        end
        if state.dumps < state.settings.dump_captures and platform.dump then
            local directory = loader.log_directory or os.getenv('LOCALAPPDATA')
            if directory then
                state.dumps = state.dumps + 1
                local path = string.format('%s/ClickableScrollbars-capture-%d-%dx%d.bmp',
                    directory, state.dumps, cursor_x, cursor_y)
                if platform.dump(sample, path) then state.last_dump = path end
            end
        end
        local local_cursor = {x = cursor_x - sample.origin_x, y = cursor_y - sample.origin_y}
        local action, reason, candidates = module.analyse(sample, local_cursor, state.settings, band)
        state.last_background = sample.background
        -- Kept for the log: it shows whether a refusal came from the pointer's tint or
        -- from list content.
        local click_r, click_g, click_b = sample.rgb(local_cursor.x, local_cursor.y)
        state.last_click_luma = click_r and luminance(click_r, click_g, click_b) or nil
        if not action then return nil, reason, candidates end
        state.last_bar_luma = action.bar.median
        action.bar_screen = {
            left = sample.origin_x + action.bar.left,
            right = sample.origin_x + action.bar.right,
            top = sample.origin_y + action.bar.top,
            bottom = sample.origin_y + action.bar.bottom,
            side = action.bar.side,
        }
        return action, reason, candidates
    end

    -- Captures are the only expensive work, so a press takes as few as possible: the
    -- known column first, then the wide strip.
    local function capture_analysis(cursor_x, cursor_y, now)
        local cached = state.bar_cache
        local cached_column = cached ~= nil and now - cached.at <= state.settings.bar_cache_ms
            and cursor_x >= cached.left - 40 and cursor_x <= cached.right + 40
        if cached_column then
            local center = math.floor((cached.left + cached.right) / 2)
            local sample = timed_capture(center, cursor_y, state.settings,
                                         state.settings.narrow_width, state.settings.narrow_window)
            if sample then
                local band = {left = cached.left - sample.origin_x - state.settings.column_tolerance,
                              right = cached.right - sample.origin_x + state.settings.column_tolerance}
                local action, reason = analysis_for(sample, cursor_x, cursor_y, band)
                if action and cursor_x >= action.bar_screen.left - state.settings.column_tolerance
                    and cursor_x <= action.bar_screen.right + state.settings.column_tolerance then
                    return action, reason
                end
                -- A refusal (content rather than track) and a black capture are
                -- decisions, not misses: no wider pass can improve them.
                if not action and reason ~= 'no_thumb' then return nil, reason end
            end
        end

        -- The wide strip must contain the bar's column (find_thumb keeps only
        -- candidates within column_tolerance of the cursor), so a bar found here
        -- is already the right one.
        local function wide_pass(window, doubled)
            local sample = timed_capture(cursor_x, cursor_y, state.settings, state.settings.strip_width, window)
            if not sample then return nil end
            local action, reason, candidates = analysis_for(sample, cursor_x, cursor_y)
            if action then
                state.bar_cache = {left = action.bar_screen.left, right = action.bar_screen.right, at = now}
                if doubled then
                    state.wide_retries = (state.wide_retries or 0) + 1
                    record('wide retry window=%d found bar=%d,%d,%d,%d', window, action.bar_screen.left,
                           action.bar_screen.top, action.bar_screen.right, action.bar_screen.bottom)
                end
            end
            return action, reason, candidates
        end

        -- A thumb taller than the strip, or a click far from it, can leave the window
        -- empty: one doubled pass keeps the click.
        local function panel_click()
            return state.last_click_luma ~= nil and state.last_background ~= nil
                and state.last_click_luma <= state.last_background + 2 * state.settings.click_contrast
        end
        local retry_window = math.min(state.settings.window * 2, state.settings.window_max)
        local can_double = retry_window > state.settings.window
        if cached_column and can_double and panel_click() then
            -- The column is known, so widening is the only thing that can help:
            -- the plain wide strip reaches no further vertically than the narrow
            -- one that just missed.
            local action, reason = wide_pass(retry_window, true)
            if action then return action, reason end
            if reason == nil then
                state.capture_failures = state.capture_failures + 1
                return nil, 'capture_failed'
            end
            return nil, reason
        end
        local action, reason, candidates = wide_pass(state.settings.window, false)
        if action then return action, reason end
        if reason == nil then
            state.capture_failures = state.capture_failures + 1
            return nil, 'capture_failed'
        end
        -- A bar-like run can be left too small to judge by a mask that is larger than the
        -- interface: one retry with half the box recovers it on the measured scale.
        if reason == 'no_thumb' and state.settings.cursor_mask and candidates then
            local masked_run = false
            for _, candidate in ipairs(candidates) do
                local width = candidate.right - candidate.left + 1
                local height = candidate.bottom - candidate.top + 1
                if width <= state.settings.max_width and height >= state.settings.min_height / 2 then
                    masked_run = true
                end
            end
            if masked_run then
                local mask = state.settings.cursor_mask
                state.settings.cursor_mask = {x0 = mask.x0 / 2, x1 = mask.x1 / 2, y0 = mask.y0 / 2,
                                              y1 = mask.y1 / 2}
                local small_action, small_reason = wide_pass(state.settings.window, false)
                state.settings.cursor_mask = mask
                if small_action then
                    state.mask_retries = (state.mask_retries or 0) + 1
                    note('mask_retry')
                    return small_action, small_reason
                end
            end
        end
        -- Only a strip that held no bar at all is worth widening: a refused
        -- click already found its bar.
        if not can_double or reason ~= 'no_thumb' or not panel_click() then return nil, reason end
        local retry_action, retry_reason = wide_pass(retry_window, true)
        if retry_action then return retry_action, retry_reason end
        return nil, retry_reason or reason
    end

    -- The thumb is tracked between captures: an injected notch moves it by
    -- about one wheel step, so the estimate stays usable while the cursor's own
    -- glow hides the bar, and every fresh observation re-anchors it.
    local function measure(sample, band, cursor)
        local tuned = module.adapt_options(sample, state.settings)
        local best = module.find_thumb(sample, cursor, tuned, band)
        if not best then return nil end
        local top, bottom = best.top + sample.origin_y, best.bottom + sample.origin_y
        local known = state.thumb_height
        if best.clipped_top and not best.clipped_bottom and known then
            return bottom - known / 2
        elseif best.clipped_bottom and not best.clipped_top and known then
            return top + known / 2
        elseif best.clipped_top and best.clipped_bottom then
            return nil
        end
        local height = bottom - top
        -- Only an unclipped run has a trustworthy height: a fragment beside the
        -- pointer sprite would otherwise teach the tracker a thumb that is far
        -- too short.
        if not best.clipped_top and not best.clipped_bottom and height >= 20
            and (not known or math.abs(height - known) < 10) then
            state.thumb_height = height
            if thumb then thumb.height = height end
        end
        return (top + bottom) / 2
    end

    -- Looks for the bar where the model expects it, with the cursor passed in so its
    -- own glow is masked and bridged.
    local function observe(target_y)
        if not thumb then return nil end
        local center_x = math.floor((thumb.left + thumb.right) / 2)
        local cursor_x, cursor_y = platform.cursor()
        local band = nil
        local sample = timed_capture(center_x, target_y, state.settings,
                                     state.settings.narrow_width, state.settings.narrow_window)
        if sample then
            band = {left = thumb.left - sample.origin_x - state.settings.column_tolerance,
                    right = thumb.right - sample.origin_x + state.settings.column_tolerance}
            local local_cursor = cursor_x and {x = cursor_x - sample.origin_x, y = cursor_y - sample.origin_y} or nil
            local center = measure(sample, band, local_cursor)
            if center then return center end
        end
        local wide = timed_capture(center_x, target_y, state.settings)
        if not wide then return nil end
        band = {left = thumb.left - wide.origin_x - state.settings.column_tolerance,
                right = thumb.right - wide.origin_x + state.settings.column_tolerance}
        local local_cursor = cursor_x and {x = cursor_x - wide.origin_x, y = cursor_y - wide.origin_y} or nil
        return measure(wide, band, local_cursor)
    end

    -- Re-anchor the tracked thumb on a measurement and, when notches were sent
    -- since the previous one, learn the wheel step the game actually produced.
    local function note_observation(center, now, settled)
        if thumb then
            check_track_bounds(center, thumb.height)
            -- Only a stopped thumb measures the step: a reading taken while the list glides
            -- understates it.
            if settled then
                local moved = injected_total - thumb.injected_at
                if moved ~= 0 then
                    local observed = math.abs(center - thumb.observed_y) / math.abs(moved)
                    if observed >= state.settings.calibration_min_px
                        and observed <= state.settings.calibration_max_px then
                        push_calibration(observed)
                    end
                end
                thumb.observed_y, thumb.observed_at, thumb.injected_at = center, now, injected_total
            end
            thumb.center_y = center
        end
    end

    -- The settle pass after a jump: it never chases the game's animation, it needs a
    -- stopped thumb, and every correction must shrink the error.
    local function service_jump(now)
        if not jump then return end
        if not wheel_target_valid() then
            jump, state.pending_units = nil, nil
            return
        end
        if now < jump.next_check then return end
        if platform.foreground_self and not platform.foreground_self() then
            -- A correction would inject wheel input into whatever window has
            -- focus: drop the verification instead.
            state.settle_unfocused = (state.settle_unfocused or 0) + 1
            note('settle_unfocused')
            jump = nil
            return
        end
        if now - last_observe_ms < state.settings.settle_interval_ms then return end
        if not budget_available(now) then
            -- Verifying the jump is worth a capture; on a machine that has
            -- already spent its share this second, the jump stands unverified
            -- rather than stalling the frame it just scrolled.
            state.settle_budget_skips = (state.settle_budget_skips or 0) + 1
            note('settle_budget')
            jump = nil
            return
        end
        last_observe_ms = now
        jump.checks = jump.checks + 1
        local centre = observe(jump.target_y)
        if not centre then
            if jump.checks >= state.settings.settle_checks then
                note('jump_unobserved')
                record('settle give_up observed=none checks=%d', jump.checks)
                jump = nil
            else
                jump.next_check = now + state.settings.settle_interval_ms
            end
            return
        end
        local residual = jump.target_y - centre
        local stable = jump.last_centre and math.abs(centre - jump.last_centre) <= state.settings.settle_stable_px
        -- Arrived where the model predicted: one reading is proof enough.
        local arrival_band = math.max(state.settings.settle_stable_px, per_notch() / 2)
        local arrived = jump.predicted ~= nil and math.abs(centre - jump.predicted) <= arrival_band
            and math.abs(jump.injected) >= 2
        note_observation(centre, now, stable)
        jump.last_centre = centre
        state.last_delta = residual
        state.last_moved = jump.baseline and (centre - jump.baseline) or nil
        if state.settings.trace_events == 1 or not stable then
            record('settle centre=%.1f residual=%.1f stable=%s check=%d/%d', centre, residual, tostring(stable),
                   jump.checks, state.settings.settle_checks)
        end
        if arrived and math.abs(residual) <= arrival_band then
            note('centered')
            record('settle arrived residual=%.1f', residual)
            jump = nil
            return
        end
        if not stable then
            -- Still moving: watch it again without touching it.
            if jump.checks >= state.settings.settle_checks then
                note('settle_timeout')
                jump = nil
            else
                jump.next_check = now + state.settings.settle_interval_ms
            end
            return
        end
        if math.abs(residual) <= state.settings.center_tolerance then
            note('centered')
            record('settle centred residual=%.1f', residual)
            jump = nil
            return
        end
        if jump.baseline and math.abs(centre - jump.baseline) <= state.settings.settle_stable_px
            and math.abs(jump.injected) >= 2 then
            -- The bar did not move at all for a multi-notch burst: this is the
            -- list end (or the game ignored the wheel). Either way, nudging
            -- again would only chatter.
            state.no_response = state.no_response + 1
            -- A multi-notch burst that moved nothing means the thumb is against
            -- the end of its track in the direction we pushed.
            learn_track_bound(jump.injected > 0 and 'top' or 'bottom', centre,
                              thumb and thumb.height or nil)
            note('no_response')
            record('settle no_response residual=%.1f injected=%d', residual, jump.injected)
            jump = nil
            return
        end
        -- Round, never round up: a residual below half a notch is left alone,
        -- which is what stops a repeat click at the same spot from moving.
        local units = math.floor(math.abs(residual) / math.max(per_notch(), 1) + 0.5)
        units = math.min(units, state.settings.correction_notches)
        if units == 0 then
            note('close_enough')
            jump = nil
            return
        end
        if jump.corrections >= state.settings.max_corrections then
            note('settled_max')
            jump = nil
            return
        end
        emit(residual > 0 and -units or units)
        jump.corrections = jump.corrections + 1
        jump.injected = jump.injected + (residual > 0 and -units or units)
        jump.predicted = centre - (residual > 0 and -units or units) * per_notch()
        jump.baseline = centre
        jump.last_centre = nil -- the moved thumb needs a fresh stable pair
        jump.next_check = now + state.settings.settle_delay_ms
        state.corrections = state.corrections + 1
        note('correcting')
        record('settle correct residual=%.1f units=%d per_notch=%.1f',
               residual, residual > 0 and -units or units, per_notch())
    end

    -- Wheel track-click handler, defined below the drag handlers.
    local start_jump

    -- Arms the drag follow. A drag carries the anchor that ties pointer to thumb, and
    -- `unmeasured` marks a press answered from the model, which has to be re-measured
    -- before the drag trusts where the bar is.
    local function begin_drag(cursor_x, cursor_y, now, left, right, side, unmeasured, track)
        local centre = thumb and thumb.center_y or nil
        drag = {start_x = cursor_x, start_y = cursor_y, last_y = cursor_y, last_raw_y = cursor_y,
                unmeasured = unmeasured, active = false,
                fraction = 0, total = 0, verified_at = now, verified_units = injected_total,
                observed_centre = centre, observe_units = injected_total,
                anchor_y = cursor_y, anchor_centre = centre,
                column_left = left, column_right = right,
                track_top = track and track.top or nil,
                track_bottom = track and (track.top + track.length) or nil}
    end

    -- The native route's one gesture: while the button is held the list's own
    -- scroll value follows the pointer, so the thumb moves by the distance the
    -- pointer moved and nothing is injected anywhere. The first write of a
    -- gesture is checked against the game's read-back. A failed route is retired
    -- for that controller; only a later gesture may use the wheel fallback.
    local function native_retire(reason)
        state.native_failed = true
        state.native_failed_key = state.native and state.native.key
        state.native_fallbacks = (state.native_fallbacks or 0) + 1
        note('native_retired')
        record('native retired (%s) after %d writes', tostring(reason), state.native_writes or 0)
    end

    -- A controller can disappear or be reused for another category during a
    -- hold. Resolve it again before writing; plausible stale memory is not proof
    -- that this is still the list the player grabbed.
    local function current_native(gesture)
        local bridge = module.native_locate(state.native_api)
        if not bridge or bridge.key ~= gesture.key then return nil end
        local model = module.native_state(bridge)
        local original = gesture.model
        if not model or model.items ~= original.items or model.kind ~= original.kind
            or math.abs(model.content - original.content) > 0.1
            or math.abs(model.span - original.span) > 0.1 then return nil end
        state.native, state.native_model = bridge, model
        return model
    end

    local function service_native_drag(now, cursor_y)
        local model = current_native(drag)
        if not model then
            drag, thumb, state.drag_active = nil, nil, false
            note('native_cancelled')
            return
        end
        -- The press snapshot is immutable for the entire gesture. Read-back
        -- refreshes the live model, never the origin of the pointer delta.
        local value = module.native_value_at_grab(drag.model, drag.track, drag.press_y, cursor_y)
        if not value then return end
        if math.abs(value - (drag.sent or drag.model.value)) > 0.000001 then
            local written, reason = module.native_apply(state.native, model, value)
            if not written then
                native_retire(reason or 'write refused')
                drag, thumb, state.drag_active = nil, nil, false
                return
            end
            if not drag.sent then state.drags = state.drags + 1 end
            state.drag_active = true
            state.native_writes = (state.native_writes or 0) + 1
            drag.sent, drag.writes = written, drag.writes + 1
            state.native_value = written
            if thumb then
                thumb.center_y = drag.track.top + written * drag.track.span + drag.track.thumb / 2
                thumb.observed_y, thumb.injected_at, thumb.observed_at = thumb.center_y, injected_total, now
            end
        end
        -- Verification also runs when the pointer stops. Small scrolls may leave
        -- the visible row indices unchanged: verify the rendered thumb in that
        -- case, instead of switching actuators halfway through a valid drag.
        if drag.sent and not drag.checked and now - drag.started >= state.settings.native_verify_ms then
            local after = module.native_state(state.native)
            local moved = after and module.native_moved(drag.model, after)
            if not moved then
                local distance = math.abs(drag.sent - drag.model.value) * drag.track.span
                if distance < 3 then return end
                -- Native geometry includes the rendered thumb. A rejected write
                -- must never invoke screen capture to verify the same gesture.
            end
            drag.checked = true
            if moved then
                state.native_ok = (state.native_ok or 0) + 1
                note('native_drag')
            else
                native_retire('the game did not answer the write')
                drag, thumb, state.drag_active = nil, nil, false
            end
        end
    end

    -- A press on the bar arms the native gesture: the list's value follows the
    -- pointer for as long as the button is held, with no capture and no input.
    -- Failure cancels this hold instead of switching input routes mid-gesture.
    local function begin_native_drag(cursor_x, cursor_y, now, thumb_centre, thumb_height, left, right, side, native_track)
        local model = state.native_model
        if not model or not thumb_centre or not thumb_height then return false end
        local track = native_track or module.native_track(model, thumb_centre - thumb_height / 2, thumb_height)
        if not track then return false end
        if state.native.route == 'settings' then
            if not module.native_settings_input(state.native) then
                note('settings_input_unavailable')
                return false
            end
            settings_capture = state.native
        end
        begin_drag(cursor_x, cursor_y, now, left, right, side, nil, track)
        drag.native, drag.track, drag.press_y = true, track, cursor_y
        drag.model, drag.key = model, state.native.key
        drag.started, drag.writes, drag.checked = now, 0, false
        record('native press y=%d track=%.1f..%.1f thumb=%.1f value=%.4f', cursor_y, track.top,
               track.top + track.length, track.thumb, model.value)
        return true
    end

    -- A press beside the bar is the native page jump: one write, the pointer's
    -- height becoming the value, with the same read-back check as a drag.
    local function native_jump(cursor_y, bar, now)
        local model = state.native_model
        if not model or state.settings.native ~= 1 or state.native_failed then return false end
        local x = select(1, platform.cursor())
        local centre = (bar.top + bar.bottom) / 2
        if not begin_native_drag(x, cursor_y, now, centre, bar.bottom - bar.top + 1,
                                 bar.left, bar.right, bar.side) then return false end
        -- Track presses use the thumb centre as their grab offset, and can
        -- continue directly into a drag without changing actuators.
        drag.press_y = centre
        service_native_drag(now, cursor_y)
        state.pages = state.pages + 1
        note('native_jump')
        return true
    end

    -- The grid is registered only while its Armory or loadout screen exists,
    -- and its controller is rebuilt with the screen, so resolution is attempted when
    -- it is needed, cached, and dropped the moment a read stops passing its
    -- bounds. A stale pointer therefore costs one failed read, never a write.
    local function refresh_native(now)
        -- Measurement is kept even after a write was refused: the grid's own
        -- geometry (content, span, value) locates the track independently of
        -- whether a later write is honoured.
        if not state.native_api then
            if state.native_api_attempted then return nil end
            state.native_api_attempted = true
            local ok, api, reason = pcall(module.native_api)
            if not ok or type(api) ~= 'table' then
                state.native_reason = tostring(reason or api)
                return nil
            end
            state.native_api = api
        end
        -- Each screen rebuilds its controller - and with it the grid - every time
        -- it is entered, so the grid is resolved from dispatch afresh
        -- on each press. A remembered pointer reads plausibly long after its screen
        -- is gone and writes into nothing, which is exactly the failure this
        -- replaces.
        local bridge, reason = module.native_locate(state.native_api)
        state.native_reason = reason
        if not bridge then
            state.native, state.native_model = nil, nil
            return nil
        end
        if state.native_failed_key and state.native_failed_key ~= bridge.key then
            -- A different screen: an earlier refusal belongs to that one.
            state.native_failed, state.native_failures = nil, 0
        end
        local model, state_reason = module.native_state(bridge)
        state.native_state_reason = state_reason
        state.native = bridge
        if not model then
            state.native_model = nil
            return nil
        end
        state.native_model = model
        return state.native
    end

    -- Turns "the thumb should sit here" into wheel input, shared by a measured press
    -- and a press answered from the burst model.
    function start_jump(cursor_y, centre, now)
        local delta = cursor_y - centre
        state.last_delta = delta
        local units = math.floor(math.abs(delta) / math.max(per_notch(), 1) + 0.5)
        if units == 0 then
            note('already_centered')
            record('jump skipped delta=%.1f (within half a step)', delta)
            return false
        end
        if now - last_jump_ms < state.settings.cooldown_ms then
            state.skipped = state.skipped + 1
            note('cooldown')
            return false
        end
        last_jump_ms = now
        units = math.min(units, state.settings.jump_max_notches)
        -- The notches wait for the release: while a button is held the game re-reads
        -- the widget under the pointer for every injected notch, so a click could
        -- press whatever else the pointer had reached.
        local press_x = select(1, platform.cursor())
        state.wheel_target = {x = press_x, y = cursor_y}
        state.pending_click = {units = delta > 0 and -units or units, target_y = cursor_y, x = press_x,
                               baseline = centre, notches = units, at = now}
        state.last_direction = delta > 0 and 'down' or 'up'
        note(delta > 0 and 'jump_down' or 'jump_up')
        record('click target=%.1f centre=%.1f delta=%.1f units=%d per_notch=%.1f (sent on release)',
               cursor_y, centre, delta, units, per_notch())
        return true
    end

    -- A click's notches go out one frame after the release, so the game has the
    -- mouse-up before any wheel arrives and cannot read the wheel as a press.
    local function service_click(now)
        local click = state.pending_click
        if not click then return end
        if not wheel_target_valid() then
            state.pending_click, state.pending_units = nil, nil
            return
        end
        local sent = emit(click.units)
        state.pending_click = nil
        state.pages = state.pages + 1
        local predicted = click.baseline - sent * per_notch()
        jump = {target_y = click.target_y, baseline = click.baseline, injected = sent, corrections = 0,
                checks = 0, predicted = predicted, next_check = now + state.settings.settle_delay_ms}
        note('click_sent')
        record('click sent units=%d target=%.1f', sent, click.target_y)
    end

    local function handle_press(now)
        state.clicks = state.clicks + 1
        if not state.settings.enabled or state.settings.native ~= 1 then return end
        if not platform.foreground_self() then return end
        -- An absent/unsupported/hidden owner is a definitive no-op. Never scan
        -- gameplay pixels looking for a possible scrollbar on an ordinary click.
        local native = refresh_native(now)
        if not native then return end
        local native_track = platform.viewport
            and module.native_screen_track(state.native_model, platform.viewport())
        if not native_track then return end
        local cursor_x, cursor_y = platform.cursor()
        if not cursor_x then return end
        if cursor_x < native_track.left - 3 or cursor_x > native_track.right + 3
            or cursor_y < native_track.top or cursor_y > native_track.top + native_track.length then
            return
        end
        if state.native_failed then return end
        thumb, jump = nil, nil
        local model = state.native_model
        local top = native_track.top + model.value * native_track.span
        local centre = top + native_track.thumb / 2
        if not begin_native_drag(cursor_x, cursor_y, now, centre, native_track.thumb,
                                 native_track.left, native_track.right, nil, native_track) then return end
        if cursor_y < top or cursor_y > top + native_track.thumb then
            drag.press_y = centre
            service_native_drag(now, cursor_y)
            state.pages = state.pages + 1
            note('native_jump')
        else
            note('bar_press')
        end
    end

    local function frame()
        local now = platform.now()
        if now == last_frame_ms then return end
        -- The game's own frame interval, used to size the capture budget: a
        -- machine already struggling to hold frames gets a smaller share of them.
        if last_frame_ms > 0 then
            local interval = clamp(now - last_frame_ms, 1, 1000)
            state.frame_interval_ms = state.frame_interval_ms and (state.frame_interval_ms * 0.9 + interval * 0.1)
                or interval
            refresh_budget()
        end
        last_frame_ms = now
        state.frames = state.frames + 1
        state.last_key = state.settings.diagnostics == 1 and platform.key_state and platform.key_state() or 0
        local down = platform.pressed()
        if down then state.down_frames = state.down_frames + 1 end
        local was_down = last_button
        local pressed = down and not was_down
        last_button = down
        -- The engine refreshes selection state each frame. Consume it before
        -- native row/tab handlers run, even if scrolling was cancelled. Resolve
        -- only the input singleton here; a previous menu owner may be gone.
        if settings_capture then
            if platform.foreground_self() and not module.native_settings_input(settings_capture) then
                drag, thumb, state.drag_active = nil, nil, false
                note('settings_input_cancelled')
            end
            if not down then settings_capture = nil end
        end
        -- Focus loss cancels ownership; resuming an old drag after alt-tab can
        -- use a different menu or deliver queued input to another application.
        if not state.settings.enabled or not platform.foreground_self() then
            drag, thumb, jump, state.drag_active = nil, nil, nil, false
            state.pending_click, state.pending_units, state.pending_native, state.wheel_target = nil, nil, nil, nil
            state.bar_cache = nil
            log(false)
            return
        end
        -- A new press ends any burst still being carried over: those notches belong
        -- to the click before it.
        if pressed then
            state.pending_units, state.pending_click, state.pending_native, state.wheel_target = nil, nil, nil, nil
            jump = nil
        end
        -- A fallback track press that becomes a hold is no longer a page click.
        if down and state.pending_click then
            local cursor_x_now, cursor_y_now = platform.cursor()
            local press = state.pending_click
            if cursor_y_now and (math.abs(cursor_y_now - press.target_y) > state.settings.drag_threshold
                or (press.x and cursor_x_now and math.abs(cursor_x_now - press.x)
                    > state.settings.drag_threshold)) then
                state.pending_click = nil
                note('click_dropped_drag')
            end
        end
        -- A click whose button has come up is sent here, one frame after the release,
        -- so the game has already seen the mouse-up when the wheel arrives.
        if not down and not was_down and state.pending_click then service_click(now) end
        if not down and not was_down and not state.pending_click then flush_pending() end
        -- Drag: the thumb travels exactly as far as the mouse. The distance is
        -- converted with the learned wheel step and sent on the frame it was
        -- measured, so no scheduler sits between the hand and the bar.
        if drag then
            if not down then
                if drag.native then
                    note('native_release')
                    record('native release writes=%d value=%s', drag.writes or 0,
                           drag.sent and string.format('%.4f', drag.sent) or 'none')
                elseif drag.active then
                    note('drag_end')
                    record('drag_end units=%d', drag.total or 0)
                end
                drag, state.drag_active = nil, false
                state.pending_units, state.pending_click = nil, nil
            elseif drag.native then
                local cursor_x, cursor_y = platform.cursor()
                if state.native_failed then
                    -- The game did not answer: drop the gesture and let every later
                    -- press use the wheel path again.
                    drag, state.drag_active = nil, false
                    note('native_dropped')
                elseif cursor_x then
                    service_native_drag(now, cursor_y)
                end
            else
                local cursor_x, cursor_y = platform.cursor()
                if cursor_x then
                    local moved_x, moved_y = cursor_x - drag.start_x, cursor_y - drag.start_y
                    if not drag.active and math.abs(moved_y) > state.settings.drag_threshold then
                        drag.active, state.drag_active = true, true
                        drag.last_y, drag.fraction = drag.start_y, 0
                        -- A hold is not a click: whatever burst the press had queued
                        -- belongs to a click that never happened.
                        state.pending_click = nil
                        -- The drag begins from here: the anchor and the stall
                        -- baseline are the press measurement, not whatever a
                        -- track click that preceded this hold may have sent.
                        local centre = thumb and thumb.center_y or nil
                        drag.observed_centre, drag.observe_units = centre, injected_total
                        drag.anchor_y, drag.anchor_centre = drag.start_y, centre
                        jump = nil
                        -- A press answered from the model may be holding a stale thumb,
                        -- and the guard that keeps notches on the bar is only as good as
                        -- that position: one reading here re-bases it on the real bar.
                        if drag.unmeasured and thumb and budget_available(now) then
                            local observed = observe(thumb.center_y)
                            if observed then
                                thumb.observed_y, thumb.injected_at, thumb.center_y =
                                    observed, injected_total, observed
                                drag.observed_centre, drag.observe_units = observed, injected_total
                                drag.anchor_y, drag.anchor_centre = drag.start_y, observed
                                record('drag anchor measured thumb=%.1f', observed)
                            end
                        end
                        state.drags = state.drags + 1
                        note('drag_start')
                        record('drag_start y=%d threshold=%d', cursor_y, state.settings.drag_threshold)
                    end
                    if drag.active then
                        local top = drag.track_top or state.track_top
                            or (thumb and thumb.observed_y - thumb.height / 2)
                        local bottom = drag.track_bottom or state.track_bottom
                            or (thumb and thumb.observed_y + thumb.height / 2)
                        local off_list = not top or not bottom or cursor_y < top or cursor_y > bottom
                        local off_column = cursor_x < drag.column_left or cursor_x > drag.column_right
                        if off_list and not drag.off_list then
                            drag.off_list = true
                            state.drag_out = (state.drag_out or 0) + 1
                            note('drag_out')
                            record('drag_out y=%d list=%s..%s', cursor_y, tostring(top), tostring(bottom))
                        elseif not off_list and drag.off_list then
                            drag.off_list = false
                            note('drag_back')
                        end
                        -- Leaving the safe target pauses the wheel route without
                        -- accumulating a burst to dump when the pointer returns.
                        if off_list or off_column or drag.outside then
                            drag.last_y, drag.fraction = cursor_y, 0
                            state.pending_units = nil
                        end
                        drag.outside = off_list or off_column
                        local wanted = cursor_y - drag.last_y
                        local delta = wanted
                        local effective = cursor_y
                        local raw_step = cursor_y - (drag.last_raw_y or cursor_y)
                        drag.last_raw_y = cursor_y
                        if math.abs(raw_step) > state.settings.drag_max_step_px then
                            -- The pointer teleported (alt-tab, display change):
                            -- re-baseline instead of flinging the list.
                            state.drag_resyncs = (state.drag_resyncs or 0) + 1
                            drag.last_y, drag.fraction = cursor_y, 0
                            delta = 0
                            note('drag_resync')
                            record('drag_resync step=%d held=%d', raw_step, wanted)
                        elseif delta ~= 0 and not off_list and not off_column then
                            drag.last_y = drag.last_y + delta
                            drag.fraction = drag.fraction - delta / math.max(per_notch(), 1)
                            -- Nearest notch, not the one below: the wheel is the only unit
                            -- the game takes, and rounding halves how far the pointer can
                            -- travel before the movement is spent -- which is what keeps a
                            -- drag that starts near the edge of the list inside it.
                            local steps = math.floor(math.abs(drag.fraction) + 0.5)
                            if steps > 0 then
                                local step = drag.fraction > 0 and 1 or -1
                                if steps > state.settings.drag_max_notches then
                                    record('drag_clamped steps=%d per_notch=%.1f', steps, per_notch())
                                    steps, drag.fraction = state.settings.drag_max_notches, 0
                                else
                                    drag.fraction = drag.fraction - step * steps
                                end
                                -- A direction whose notches the list did not answer is held
                                -- until the pointer turns around: the list is at its end, and
                                -- pushing on would only spend notches it ignores.
                                if drag.held_units and step ~= drag.held_units then
                                    drag.held_units, drag.held = nil, false
                                    note('drag_release')
                                end
                                if drag.held_units == step then
                                    state.drag_limits = (state.drag_limits or 0) + 1
                                    -- The movement is not spent, it is kept: the bar has to
                                    -- end up where the pointer says even though this stretch
                                    -- of the drag could not move it.
                                    drag.fraction = drag.fraction + delta / math.max(per_notch(), 1)
                                    steps = 0
                                    if not drag.held then
                                        drag.held = true
                                        note('drag_limit')
                                        record('drag_limit step=%d (the list did not answer)', step)
                                    end
                                end
                                -- Never push past an end the game has shown us.
                                local allowed = steps
                                if thumb and thumb.height then
                                    local notch = math.max(per_notch(), 1)
                                    if step > 0 and state.track_top then
                                        local room = (thumb.center_y - thumb.height / 2) - state.track_top
                                        allowed = math.min(allowed, math.max(0, math.floor(room / notch + 1e-6)))
                                    elseif step < 0 and state.track_bottom then
                                        local room = state.track_bottom - (thumb.center_y + thumb.height / 2)
                                        allowed = math.min(allowed, math.max(0, math.floor(room / notch + 1e-6)))
                                    end
                                end
                                if allowed < steps then
                                    state.track_blocked = (state.track_blocked or 0) + (steps - allowed)
                                    drag.fraction = 0
                                    drag.limits = (drag.limits or 0) + 1
                                    state.drag_limits = (state.drag_limits or 0) + 1
                                    note('drag_limit')
                                    record('drag_limit step=%d wanted=%d allowed=%d', step, steps, allowed)
                                    -- A hint that keeps blocking is wrong: give up on
                                    -- it and let the drag carry on rather than
                                    -- letting a stale end freeze the scrollbar.
                                    if state.track_blocked > state.settings.track_clamp_max_notches then
                                        drop_track_bounds('clamp exceeded')
                                        allowed = steps
                                        drag.fraction = 0
                                    end
                                end
                                if allowed > 0 then
                                    local sent = math.abs(emit(step * allowed))
                                    drag.total = (drag.total or 0) + sent
                                    state.drag_notches = (state.drag_notches or 0) + sent
                                    state.last_direction = step > 0 and 'up' or 'down'
                                    drag.last_step = step
                                end
                                if state.settings.trace_events == 1 then
                                    record('drag_move delta=%d wanted=%d sent=%d', delta, steps, allowed)
                                end
                            end
                        end
                        -- Re-anchor the drag now and then. This both corrects the
                        -- open-loop drift of a long drag and tells us when the
                        -- thumb has stopped, which means the list is at an end.
                        local unverified = math.abs(injected_total - (drag.verified_units or injected_total))
                        local due = unverified >= state.settings.drag_verify_notches
                        -- Away from the thumb the drag is guessing, and every guessed notch
                        -- lands wherever the pointer is: check at once instead of after the
                        -- usual few, so a wrong guess costs one notch instead of six.
                        local away = thumb and unverified > 0
                            and math.abs(cursor_y - thumb.observed_y) > thumb.height / 2
                                + state.settings.thumb_margin
                        if away then due = true end
                        local gap = away and state.settings.drag_verify_ms / 3
                            or state.settings.drag_verify_ms
                        if due and now - (drag.verified_at or now) >= gap
                            and budget_available(now) then
                            -- The grab offset keeps the pointer off the thumb, so look where the model says.
                            local predicted = thumb and thumb.center_y or nil
                            local observed = observe(predicted or cursor_y)
                            drag.verified_at, drag.verified_units = now, injected_total
                            state.drag_verifies = (state.drag_verifies or 0) + 1
                            -- A stopped thumb drifts from the model, so a reading near the last one counts too.
                            if observed and predicted then
                                local tolerance = math.max(3 * math.max(per_notch(), 1),
                                                           thumb and thumb.height or 0)
                                local near_model = math.abs(observed - predicted) <= tolerance
                                local near_last = drag.observed_centre ~= nil
                                    and math.abs(observed - drag.observed_centre) <= tolerance
                                if not near_model and not near_last then
                                    state.drag_rejects = (state.drag_rejects or 0) + 1
                                    note('drag_reject')
                                    record('drag_verify rejected observed=%.1f predicted=%.1f', observed,
                                           predicted)
                                    observed = nil
                                end
                            end
                            if observed then
                                local sent = injected_total - (drag.observe_units or injected_total)
                                local expected = -sent * per_notch()
                                local seen = observed - (drag.observed_centre or observed)
                                local still = math.abs(seen) <= math.max(state.settings.settle_stable_px,
                                                                        per_notch() / 4)
                                -- Nothing moved although notches went out: that direction is
                                -- held until the pointer turns around, so the drag waits at the
                                -- end of the list instead of spending notches it ignores.
                                if still and math.abs(expected) >= state.settings.drag_verify_notches
                                    * math.max(per_notch(), 1) then
                                    drag.stall_confirm = (drag.stall_confirm or 0) + 1
                                    if sent ~= 0
                                        and drag.stall_confirm == state.settings.drag_stall_confirmations
                                        and drag.held_units ~= (sent > 0 and 1 or -1) then
                                        drag.held_units, drag.held = (sent > 0 and 1 or -1), false
                                        -- Nothing answered those notches, so they are owed
                                        -- back to the pointer: the drag keeps its aim
                                        -- instead of drifting by everything the list ignored.
                                        drag.fraction = drag.fraction + sent
                                        -- A stall measured with the pointer on the thumb is the
                                        -- list's own end: that is the one place it can be
                                        -- learned from, and it bounds the next drag's travel.
                                        if thumb and thumb.height and
                                            math.abs(cursor_y - observed) <= thumb.height / 2 then
                                            learn_track_bound(sent > 0 and 'top' or 'bottom', observed,
                                                              thumb.height)
                                        end
                                        state.drag_stalls = (state.drag_stalls or 0) + 1
                                        note('drag_stall')
                                        record('drag_stall centre=%.1f expected=%.1f units=%d', observed,
                                               expected, sent)
                                    end
                                elseif seen ~= 0 then
                                    drag.stall_confirm = 0
                                    drag.held_units, drag.held = nil, false
                                end
                                drag.observed_centre, drag.observe_units = observed, injected_total
                                drag.anchor_y, drag.anchor_centre = cursor_y, observed
                                -- Re-base the model on every reading, so an open-loop drag
                                -- cannot drift away from the bar it is following.
                                if thumb then
                                    thumb.observed_y, thumb.injected_at, thumb.center_y =
                                        observed, injected_total, observed
                                end
                            end
                        end
                    end
                end
            end
        end
        if pressed then
            state.frame_clicks = state.frame_clicks + 1
            -- handle_press refuses a background press itself, and counting that
            -- refusal is what the log's `not_foreground` numbers report.
            handle_press(now)
        end
        service_jump(now)
        local elapsed = platform.now() - now
        state.frame_ms_total = state.frame_ms_total + elapsed
        if elapsed > state.frame_ms_max then state.frame_ms_max = elapsed end
        log(false)
    end

    -- A failing frame is counted, its half-finished interaction dropped, and the addon
    -- stops only after error_limit of them.
    local function guard(label)
        local ok, reason = pcall(frame)
        if ok then return true end
        state.errors = state.errors + 1
        state.last_error = tostring(reason)
        drag, state.drag_active, jump = nil, false, nil
        state.pending_units, state.pending_click, state.pending_native, state.wheel_target = nil, nil, nil, nil
        note('frame_error')
        record('error %s #%d: %s', label, state.errors, tostring(reason))
        if state.errors >= state.settings.error_limit then
            stopped = true
            state.status = 'stopped: ' .. tostring(reason)
        end
        log(true)
        return false
    end

    environment.update = function(dt, ...)
        if not stopped then guard('update') end
        if type(previous_update) == 'function' then
            return previous_update(dt, ...)
        end
    end
    environment.shutdown = function(...)
        stopped = true
        settings_capture = nil
        state.status = 'stopped'
        record('shutdown frames=%d clicks=%d pages=%d', state.frames or 0, state.clicks or 0, state.pages or 0)
        log(true)
        pcall(platform.close)
        if type(previous_shutdown) == 'function' then
            return previous_shutdown(...)
        end
    end

    -- Only update owns input processing. Running it again from render can
    -- double the native reads and log work within a single displayed frame.
    refresh_geometry(true)
    state.status = state.settings.enabled and 'running' or 'disabled: config'
    log(true)
    return state
end

if rawget(_G, '__CLICKABLE_SCROLLBARS_TEST') then
    return module
end

local ok, reason = module.install(module.create_platform)
if not ok then
    local loader = rawget(_G, 'CowboyBingusModLoader')
    print('[ClickableScrollbars] ' .. tostring(reason))
    pcall(function()
        local file = loader and loader.open_log and loader.open_log('ClickableScrollbars.log')
        if file then
            file:write(module.revision .. '\nstatus=' .. tostring(reason) .. '\n')
            file:close()
        end
    end)
end
