-- The UI bridge, the native grid's layout in this build, the game's scroll and
-- input routines, and the native writes that drive them.
local module, cs = ...

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

-- The largest block native_state reads at once (the grid's row-table block).
local BLOCK_BYTES = 4352
local CAREER = {offset = 318472, list = 2488, track = 195256, thumb = 195808,
                thumb_height = 196148, enabled = 196089, padding = 4}
local LOADOUT_GRID_OFFSET = 864032
-- Both the settings page and Bindings own inline virtual lists of the same
-- widget type. Page offsets were measured in Steam build 25480438.
local OPTIONS_LIST = {bar = 816, thumb = 1432,
                      scroll = 552, span = 2784, value = 2792}
local OPTIONS_PAGES = {
    [1] = {menu = 200, list = 4189984, route = 'settings'},
    [26] = {menu = 208, list = 338344, route = 'bindings'},
}
local GRID_SOLVER, SCROLL_SET, POSITION_SET, ANIMATION_STOP =
    0x18d2b60, 0x1794530, 0x14476a0, 0x1439d40
local INPUT_CONSUME, INPUT_STATE, UI_SELECT = 0x12fde90, 0x347cf18, 0xA00000000
module.native_signatures = {
    {GRID_SOLVER, '488bc45355565741544155415641574881ecf800000083b9'},
    {SCROLL_SET, '0f57d20f2fd1770cf30f10153028c300f30f5dd1f30f1081'},
    {POSITION_SET, '48895c241848896c24204889542410565741574883ec20f3'},
    {ANIMATION_STOP, '40534883ec40488b05c32220014833c448894424300fb601'},
    {INPUT_CONSUME, '40534883ec204c8bd14c8bca488bcae8dc7c28ff'},
}

local function native_key(pointer)
    if type(pointer) == 'cdata' then
        pointer = tonumber(require('ffi').cast('uintptr_t', pointer))
    end
    -- The game's tostring hides cdata values as "[cdata (deleted)]".
    return string.format('%.0f', pointer)
end

-- The native layer carries the two small predicates it needs rather than
-- sharing clamp: its functions stay in the interpreter (keep_interpreted), and
-- a shared clamp would keep the per-frame steps' calls of it there too.
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

-- Function pointer and vector types, declared once per process by name. A type
-- string such as 'void (*)(void *)' creates new C types every time it is cast,
-- and the type table every mod shares never frees them (65536 entries). The
-- union packs the two-float vector through one base, so compiled code cannot
-- read it back stale.
local NATIVE_TYPES = [[
    typedef void (*hd2cs_native_ptr)(void *);
    typedef void (*hd2cs_native_ptr_float)(void *, float);
    typedef void (*hd2cs_native_ptr_u64)(void *, uint64_t);
    typedef void (*hd2cs_native_ptr_u64_float)(void *, uint64_t, float);
    typedef union { float f[2]; uint64_t u; } hd2cs_vec2_bits;
]]
local native_cache = {}

-- Use the same setters and layout sequence as the game's scroll handlers.
-- A raw value write skips the thumb update; an active animation can overwrite
-- the requested position. Native calls execute from the loader's frame callback.
-- The functions are cast once per game module base and reused for the session.
function module.native_calls(bridge)
    local ffi = require('ffi')
    local game = bridge.game
    -- api.module returns a new pointer object each time; key the cache by address.
    local key = type(game) == 'number' and game or tonumber(ffi.cast('uintptr_t', game))
    local cached = native_cache[key]
    if cached then return cached end
    if not pcall(ffi.typeof, 'hd2cs_vec2_bits') then ffi.cdef(NATIVE_TYPES) end
    local ptr, ptr_float = ffi.typeof('hd2cs_native_ptr'), ffi.typeof('hd2cs_native_ptr_float')
    local ptr_u64, ptr_u64_float = ffi.typeof('hd2cs_native_ptr_u64'), ffi.typeof('hd2cs_native_ptr_u64_float')
    local stop = ffi.cast(ptr, game + ANIMATION_STOP)
    local scroll = ffi.cast(ptr_float, game + SCROLL_SET)
    local position = ffi.cast(ptr_u64, game + POSITION_SET)
    local solve = ffi.cast(ptr, game + GRID_SOLVER)
    local consume = ffi.cast(ptr_u64_float, game + INPUT_CONSUME)
    local bytes = ffi.typeof('uint8_t *')
    local xy = ffi.new('hd2cs_vec2_bits')
    local calls = {}
    -- The last grid's animation flag and stop target, so that a drag frame
    -- computes no pointer.
    local stop_grid, stop_flag, stop_target
    function calls.stop(grid)
        if grid ~= stop_grid then
            stop_grid, stop_flag, stop_target = grid, ffi.cast(bytes, grid + 600322), grid + 600320
        end
        if stop_flag[0] ~= 0 then stop(stop_target) end
    end
    function calls.scroll(bar, value)
        scroll(bar, value)
    end
    function calls.position(widget, x, y)
        -- The engine passes its two-float vector in the second integer register.
        -- An FFI struct argument is not interchangeable with that ABI.
        xy.f[0], xy.f[1] = x, y
        position(widget, xy.u)
    end
    function calls.solve(grid)
        solve(grid)
    end
    function calls.consume(input, action)
        -- Match the game's buttons: -1 consumes this action until release.
        -- Action ids are below 2^53, so the number converts to uint64_t exactly.
        consume(input, action, -1)
    end
    native_cache[key] = calls
    return calls
end

-- The game routines, looked up once per resolved owner.
local function owner_calls(bridge)
    local calls = bridge.calls
    if not calls then
        calls = module.native_calls(bridge)
        bridge.calls = calls
    end
    return calls
end

-- The addresses a route writes, computed once per resolved owner so that a drag
-- frame computes no pointer.
local function write_targets(bridge)
    local targets = bridge.targets
    if targets then return targets end
    local route = bridge.route
    if route == 'career' then
        targets = {list = bridge.panel + CAREER.list}
    elseif route == 'bindings' or route == 'settings' then
        targets = {content = bridge.grid + 544}
    else
        targets = {bar = bridge.grid + 272, scroll = bridge.grid + GRID.scroll}
    end
    bridge.targets = targets
    return targets
end

-- Runs under pcall in native_apply (a named function, so no closure per drag frame).
local function apply_native(bridge, model, value, calls)
    calls = calls or owner_calls(bridge)
    local targets = write_targets(bridge)
    if bridge.route == 'career' then
        -- Career scrolls a container. Its frame update derives the thumb
        -- from (container.y + padding) / (content - viewport).
        calls.position(targets.list, model.list_x, value * model.span - CAREER.padding)
    elseif bridge.route == 'bindings' or bridge.route == 'settings' then
        -- The game's list input handler updates both objects in this order:
        -- the scrollbar value, then the content container's vertical
        -- position. Updating only the bar moves the thumb but not rows.
        calls.scroll(bridge.bar, value)
        calls.position(targets.content, 0, value * model.span)
    else
        -- Follow the game's wheel handler: stop an existing animation,
        -- update the scrollbar (including its rendered thumb), then layout.
        -- Writing value first would make the native setter skip its work.
        calls.stop(bridge.grid)
        calls.scroll(targets.bar, value)
        if not bridge.memory.write_f32(targets.scroll, value * model.span) then
            calls.scroll(targets.bar, model.value)
            error('scroll write refused', 0)
        end
        calls.solve(bridge.grid)
    end
end

function module.native_apply(bridge, model, value, calls)
    if type(bridge) ~= 'table' or not bridge.memory or not model
        or type(value) ~= 'number' or value ~= value
        or not model.span or model.span <= 0 or model.span ~= model.span
        or model.span > GRID.max_pixels then return nil, 'invalid native target' end
    value = native_clamp(value, 0, 1)
    local ok, err = pcall(apply_native, bridge, model, value, calls)
    if not ok then return nil, tostring(err) end
    return value
end

-- Settings rows and tabs both read UI_SELECT, including its held value. The
-- list's 0.5-second timer is not a capture gate: its update adds dt before row
-- input, and tabs bypass it entirely. Consume the selection through the same
-- engine routine used by buttons; it clears all frame copies and held values.
-- The OS button/cursor remain untouched and continue driving our scroll model.
-- The input owner is read every frame of a settings hold (a previous menu owner
-- may be gone), but decoded again only when its pointer's bytes change.
local function input_owner(bridge)
    local api, slot = bridge.api, bridge.input_slot
    if not slot then
        slot = bridge.game + INPUT_STATE
        bridge.input_slot = slot
    end
    local bytes = api.read(slot, 8)
    if bytes ~= bridge.input_bytes then
        bridge.input_bytes, bridge.input = bytes, api.pointer(bytes)
    end
    return bridge.input
end

local function consume_select(bridge, calls)
    local input = input_owner(bridge)
    if not input then return false end
    calls = calls or owner_calls(bridge)
    return calls.consume(input, UI_SELECT) ~= false
end

function module.native_settings_input(bridge, calls)
    if not bridge or bridge.route ~= 'settings' or not bridge.api or not bridge.game then
        return nil, 'not a settings list'
    end
    local ok, result = pcall(consume_select, bridge, calls)
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

-- For the files that read the same objects.
cs.GRID, cs.BLOCK_BYTES, cs.CAREER, cs.LOADOUT_GRID_OFFSET = GRID, BLOCK_BYTES, CAREER, LOADOUT_GRID_OFFSET
cs.OPTIONS_LIST, cs.OPTIONS_PAGES = OPTIONS_LIST, OPTIONS_PAGES
cs.native_key, cs.native_clamp, cs.native_address = native_key, native_clamp, native_address

cs.keep_interpreted({module.native_calls, module.native_apply, apply_native, owner_calls, write_targets,
    module.native_settings_input, consume_select, input_owner, module.native_moved, module.native_value_at_grab,
    module.native_value, module.native_track, module.native_set, native_clamp, native_address, native_key})
