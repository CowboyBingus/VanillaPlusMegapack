-- The owner's scroll model: its fields, read in blocks, and the track on screen.
local module, cs = ...
local GRID, BLOCK_BYTES, CAREER, OPTIONS_LIST = cs.GRID, cs.BLOCK_BYTES, cs.CAREER, cs.OPTIONS_LIST
local native_clamp, native_address = cs.native_clamp, cs.native_address

-- The model's fields by byte offset from the route's base object, grouped in
-- blocks the shipped reader fetches with one read each. A field is {name,
-- offset, float?}; a block's first byte and size cover its fields. Scrollbar
-- widgets: +12 width, +16 height, +100 and +140 UI scale, +148 left, +156
-- bottom (the thumb's rendered position).
local function seal(fields)
    local first, last = math.huge, -1
    for _, field in ipairs(fields) do
        first, last = math.min(first, field[2]), math.max(last, field[2] + 4)
    end
    for _, field in ipairs(fields) do assert((field[2] - first) % 4 == 0, 'unaligned model field') end
    assert(last - first <= BLOCK_BYTES, 'model block too large')
    fields.first, fields.size = first, last - first
    return fields
end

local function block_of(fields, ...)
    for _, field in ipairs({...}) do fields[#fields + 1] = field end
    return seal(fields)
end

local function widget_fields(bar, thumb)
    return {{'bar_width', bar + 12, true}, {'bar_height', bar + 16, true}, {'bar_sx', bar + 100, true},
            {'bar_sy', bar + 140, true}, {'bar_left', bar + 148, true}, {'bar_bottom', bar + 156, true},
            {'thumb_height', thumb + 16, true}, {'rendered_thumb', thumb + 156, true}}
end

local MODEL_LAYOUT = {
    -- From the grid; its bar widget is at +272, its thumb at +888.
    grid = {
        block_of(widget_fields(272, 888), {'span', GRID.span, true}, {'value', GRID.value, true}),
        block_of({}, {'columns', GRID.columns, false}),
        block_of({}, {'rows', GRID.rows, false}, {'selected', GRID.selected, false}, {'scroll', GRID.scroll, true},
                 {'content', GRID.content, true}, {'items', GRID.items, false}, {'kind', GRID.kind, false},
                 {'anchor', GRID.anchor, false}),
        block_of({}, {'first', GRID.first, false}, {'last', GRID.last, false}),
    },
    -- From the Career panel: its list container and its bar (track) and thumb.
    career = {
        block_of({}, {'list_x', CAREER.list + 4, true}, {'list_y', CAREER.list + 8, true},
                 {'list_height', CAREER.list + 16, true}, {'list_scale', CAREER.list + 32, true}),
        block_of(widget_fields(CAREER.track, CAREER.thumb)),
    },
    -- From the options list.
    options = {
        block_of(widget_fields(OPTIONS_LIST.bar, OPTIONS_LIST.thumb), {'scroll', OPTIONS_LIST.scroll, true},
                 {'span', OPTIONS_LIST.span, true}, {'value', OPTIONS_LIST.value, true}),
    },
}

-- The fields last read by native_state (it is never re-entered).
local raw = {}

-- One read per field: views without read_block (offline readers).
local function read_each(memory, base, layout)
    for _, block in ipairs(layout) do
        for _, field in ipairs(block) do
            local read = field[3] and memory.read_f32 or memory.read_u32
            raw[field[1]] = read(base + field[2])
        end
    end
end

-- A block that cannot be read leaves its fields nil, as a failed field read does.
local function decode_block(memory, block, loaded)
    local first, floats, words = block.first, memory.block_f32, memory.block_u32
    for _, field in ipairs(block) do
        local value = nil
        if loaded then
            local slot = (field[2] - first) / 4
            if field[3] then value = floats[slot] else value = words[slot] end
        end
        raw[field[1]] = value
    end
end

-- One read per block. The block addresses are computed once per resolved
-- owner, so a repeated read does no pointer arithmetic.
local function read_blocks(bridge, base, layout)
    local memory, addresses = bridge.memory, bridge.blocks
    if not addresses then
        addresses = {}
        for index, block in ipairs(layout) do addresses[index] = base + block.first end
        bridge.blocks = addresses
    end
    for index, block in ipairs(layout) do
        decode_block(memory, block, memory.read_block(addresses[index], block.size))
    end
end

local function read_fields(bridge, base, layout)
    if bridge.memory.read_block then return read_blocks(bridge, base, layout) end
    read_each(bridge.memory, base, layout)
end

local function off_scale(number)
    return number ~= number or math.abs(number) > GRID.max_pixels
end

-- The scrollbar's track and thumb, from raw.
local function native_geometry(model)
    local height, width, sx, sy = raw.bar_height, raw.bar_width, raw.bar_sx, raw.bar_sy
    local left, bottom, thumb = raw.bar_left, raw.bar_bottom, raw.thumb_height
    if not (height and width and sx and sy and left and bottom and thumb) then
        return nil, 'scrollbar geometry unreadable'
    end
    if off_scale(height) or off_scale(width) or off_scale(sx) or off_scale(sy) or off_scale(left)
        or off_scale(bottom) or off_scale(thumb) then return nil, 'scrollbar geometry out of range' end
    if height <= 0 or width <= 0 or sx <= 0 or sy <= 0 or thumb <= 0 or thumb >= height then
        return nil, 'scrollbar not scrollable'
    end
    model.thumb_ratio = thumb / height
    local geometry = model.geometry or {}
    geometry.left, geometry.bottom, geometry.width = left, bottom, width * sx
    geometry.length, geometry.thumb = height * sy, thumb * sy
    model.geometry = geometry
    model.rendered_thumb = raw.rendered_thumb
    return model
end

-- Career scrolls a container; the bar's height is its viewport.
local function career_model(model)
    local height, scale, viewport = raw.list_height, raw.list_scale, raw.bar_height
    local y, x = raw.list_y, raw.list_x
    if not (height and scale and viewport and y and x) then return nil, 'career unreadable' end
    local content, span = height * scale, height * scale - viewport
    if content ~= content or content > GRID.max_pixels or span ~= span or span <= 0
        or y ~= y or math.abs(y) > GRID.max_pixels or x ~= x then return nil, 'career out of range' end
    model.content, model.span, model.viewport = content, span, viewport
    model.scroll, model.list_x, model.kind = y + CAREER.padding, x, 'career'
    model.value = native_clamp((y + CAREER.padding) / span, 0, 1)
    return native_geometry(model)
end

local function options_model(model, route)
    local span, value, scroll, viewport = raw.span, raw.value, raw.scroll, raw.bar_height
    if not (span and value and scroll and viewport) or span ~= span or value ~= value
        or scroll ~= scroll or span <= 0 or span > GRID.max_pixels
        or value < -0.001 or value > 1.001 or viewport <= 0
        or viewport > GRID.max_pixels or scroll < -1 or scroll > span + 1 then
        return nil, 'bindings list out of range'
    end
    model.content, model.span, model.viewport = span + viewport, span, viewport
    model.value, model.scroll, model.kind = native_clamp(value, 0, 1), scroll, route
    return native_geometry(model)
end

local GRID_MODEL_FIELDS = {'columns', 'rows', 'items', 'kind', 'selected', 'first', 'last', 'anchor', 'content',
                           'span', 'value', 'scroll'}

-- The reason a grid's counts or pixel sizes do not fit this build, or nil.
local function grid_refusal(model)
    if not (model.columns and model.rows and model.items) then return 'grid state unreadable' end
    if model.columns < 1 or model.columns > GRID.max_columns then return 'grid columns out of range' end
    if model.rows < 1 or model.rows > GRID.max_rows then return 'grid rows out of range' end
    if model.items < 1 or model.items > GRID.max_items then return 'grid item count out of range' end
    local content, value, span = model.content, model.value, model.span
    if not content or content ~= content or content <= 0 or content > GRID.max_pixels then
        return 'grid content out of range'
    end
    if not value or value ~= value or value < -0.001 or value > 1.001 then return 'grid value out of range' end
    if not span or span ~= span or span <= 0 or span > GRID.max_pixels then return 'grid span out of range' end
    return nil
end

local function grid_model(model)
    for _, name in ipairs(GRID_MODEL_FIELDS) do model[name] = raw[name] end
    local refusal = grid_refusal(model)
    if refusal then return nil, refusal end
    model.value = native_clamp(model.value, 0, 1)
    model.viewport = model.content - model.span
    if model.viewport <= 0 then return nil, 'grid not scrollable' end
    return native_geometry(model)
end

-- Every field a model may hold except its geometry table, which a refilled
-- model keeps and overwrites.
local MODEL_FIELDS = {'columns', 'rows', 'items', 'kind', 'selected', 'first', 'last', 'anchor', 'content',
                      'span', 'value', 'scroll', 'viewport', 'list_x', 'thumb_ratio', 'rendered_thumb'}

-- Read the list's own scroll model, with the bounds the offsets were measured
-- under. A model that does not look like this build's grid is refused rather
-- than written to. With into, that table is refilled instead of a new one (a
-- held drag's live model); every field is set again, so nothing of a model of
-- another route survives.
function module.native_state(bridge, into)
    if type(bridge) ~= 'table' or not native_address(bridge.grid) or type(bridge.memory) ~= 'table' then
        return nil, 'not resolved'
    end
    local model = into or {}
    for _, name in ipairs(MODEL_FIELDS) do model[name] = nil end
    local route = bridge.route
    if route == 'career' then
        read_fields(bridge, bridge.panel, MODEL_LAYOUT.career)
        return career_model(model)
    end
    if route == 'bindings' or route == 'settings' then
        read_fields(bridge, bridge.grid, MODEL_LAYOUT.options)
        return options_model(model, route)
    end
    read_fields(bridge, bridge.grid, MODEL_LAYOUT.grid)
    return grid_model(model)
end

-- Translate the native bottom-left origin to desktop pointer coordinates.
function module.native_screen_track(model, viewport)
    local g = model and model.geometry
    if not g or not viewport or not viewport.height then return nil end
    return {left = viewport.x + g.left, right = viewport.x + g.left + g.width,
            top = viewport.y + viewport.height - g.bottom - g.length,
            length = g.length, thumb = g.thumb, span = g.length - g.thumb}
end

cs.keep_interpreted({module.native_state, read_fields, read_blocks, read_each, decode_block, native_geometry,
    career_model, options_model, grid_refusal, grid_model, off_scale, module.native_screen_track})
