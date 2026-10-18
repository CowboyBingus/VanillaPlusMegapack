-- Game-behaviour simulator: a synthetic game (measured layout, animated and clamped
-- list, wheel hit-testing, widget activation) plus the real addon, asserted on what a
-- player notices. Numbers behind it: docs/RESEARCH.md.

package.path = (arg and arg[1] or '.') .. '/?.lua;' .. package.path

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local SOURCE = (arg and arg[2]) or 'ClickableScrollbars/src/clickable_scrollbars.lua'
local module = assert(loadfile(SOURCE))()

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL ' .. name .. (detail and (' - ' .. tostring(detail)) or ''))
    end
end

local FRAME_MS = 1000 / 60
local CAPTURE_COST_MS = 1.9      -- their log: capture_ms_avg 1.938 on the desktop DC
local PIXEL_COST_MS = 0.00002

-- ------------------------------------------------------------ measured layout

local REF = {
    height = 1440,                 -- the display the constants were measured on
    column = {x0 = 1528, x1 = 1537},   -- the scrollbar column: 10 px thick
    list = {y0 = 420, y1 = 1180},      -- the list viewport
    tab_row = {y0 = 352, y1 = 410},    -- the top tab strip, Q/E prompts at its end
    sub_row = {y0 = 296, y1 = 346},    -- the sub-tab strip, Z/C prompts
    grid = {x0 = 700, x1 = 1465},      -- item artwork: right edge 63 px left of the column
    spine = 41,                    -- nearest interface content left of the column
    content = 3140,                -- list content height (184 px thumb, as measured)
    thumb_step = 13,               -- px of thumb travel per wheel notch (calibrated live)
}

-- ------------------------------------------------------------------ the game

local function new_game(options)
    options = options or {}
    local scale = options.scale or 1
    local content = (options.content or REF.content) * scale
    local game = {
        scale = scale,
        time = 1000,
        -- The viewport height the addon is told about; the interface need not follow it.
        height = math.floor(options.reported_height or (REF.height * scale)),
        -- The layout is continuous and the renderer antialiases its edges, so the
        -- bar keeps its true thickness at any scale (a 10 px bar is 6.93 px at
        -- 0.693 and reads back as 7). Hit-testing uses the same continuous edges.
        column = {x0 = REF.column.x0 * scale, x1 = (REF.column.x1 + 1) * scale},
        list = {y0 = math.floor(REF.list.y0 * scale), y1 = math.floor(REF.list.y1 * scale)},
        tab_row = {y0 = math.floor(REF.tab_row.y0 * scale), y1 = math.floor(REF.tab_row.y1 * scale)},
        sub_row = {y0 = math.floor(REF.sub_row.y0 * scale), y1 = math.floor(REF.sub_row.y1 * scale)},
        grid = {x0 = math.floor(REF.grid.x0 * scale), x1 = math.floor(REF.grid.x1 * scale)},
        spine = math.floor(REF.spine * scale),
        content = math.floor(content),
        thumb_step = (options.thumb_step or REF.thumb_step) * scale,
        min_thumb = math.floor(176 * scale),
        widgets = {},
        activations = {},
        wheels = {},
        captures = 0,
        capture_ms = 0,
    }
    local function widget(name, row, x0, x1)
        game.widgets[#game.widgets + 1] = {name = name, x0 = x0, x1 = x1, y0 = row.y0, y1 = row.y1}
    end
    -- The tab strips, and the Q/E and Z/C prompts inside them: their labels end
    -- 41 px left of the bar, and their hit areas allow for another 11 px of padding.
    local prompt_edge = game.column.x0 - math.floor(30 * scale)
    widget('tabs', game.tab_row, game.grid.x0, prompt_edge)
    widget('subtabs', game.sub_row, game.grid.x0, prompt_edge)
    -- Item tiles beside the bar, inside the list: a sideways-wandering drag that
    -- reached them would re-click the item under the pointer.
    local tile = math.floor(180 * scale)
    for index = 0, 4 do
        local right = game.grid.x1 - tile * index
        game.widgets[#game.widgets + 1] = {name = 'item' .. index, x0 = right - tile, x1 = right,
                                           y0 = game.list.y0, y1 = game.list.y1}
    end

    function game.now() return game.time end

    function game.thumb_height()
        local viewport = game.list.y1 - game.list.y0
        return math.max(game.min_thumb, viewport * viewport / math.max(1, content))
    end

    function game.thumb_top()
        local viewport = game.list.y1 - game.list.y0
        local room = math.max(0, viewport - game.thumb_height())
        return game.list.y0 + (game.offset / math.max(1, game.travel)) * room
    end

    function game.widget_at(x, y)
        for _, item in ipairs(game.widgets) do
            if x >= item.x0 and x <= item.x1 and y >= item.y0 and y <= item.y1 then return item end
        end
        return nil
    end

    local viewport = game.list.y1 - game.list.y0
    game.travel = game.content - viewport
    game.room = viewport - game.thumb_height()
    -- One notch moves the thumb the measured step, so the content moves by the
    -- step scaled by the track's gearing.
    game.content_per_notch = game.thumb_step * game.travel / math.max(1, game.room)
    game.offset = math.floor(options.offset or (game.travel / 2))
    game.target = game.offset

    -- The game hit-tests a wheel where the pointer is, and re-reads the held widget.
    function game.wheel(notches, x, y, button_held)
        game.wheels[#game.wheels + 1] = {notches = notches, x = x, y = y, held = button_held,
                                         top = game.thumb_top(),
                                         bottom = game.thumb_top() + game.thumb_height()}
        local over_list = y >= game.list.y0 and y <= game.list.y1
            and x >= game.grid.x0 and x <= game.column.x1
        if over_list then
            game.target = game.target - notches * game.content_per_notch
            local travel = game.travel
            if game.target < 0 then game.target = 0 end
            if game.target > travel then game.target = travel end
        end
        if button_held then
            local hit = game.widget_at(x, y)
            -- Confirmed live: a wheel that arrives while the button is held presses
            -- whatever is under the pointer -- tabs and list items alike.
            if hit then game.activations[#game.activations + 1] = hit.name end
        end
    end

    function game.advance(milliseconds)
        game.time = game.time + milliseconds
        -- The list animates towards its target, like the game's own scroll.
        game.offset = game.offset + (game.target - game.offset) * (1 - math.exp(-milliseconds / 55))
    end

    return game
end

-- --------------------------------------------------------------- the platform

local function new_platform(game)
    local platform = {
        game = game,
        down = false,
        pointer = {x = (game.column.x0 + game.column.x1) / 2, y = game.list.y0 + 200 * game.scale},
    }
    function platform.now() return game.now() end
    function platform.cursor() return platform.pointer.x, platform.pointer.y end
    function platform.pressed() return platform.down end
    function platform.key_state() return platform.down and 0x8000 or 0 end
    function platform.foreground_self() return platform.focused ~= false end
    function platform.display_height() return game.height end
    function platform.close() end
    function platform.wheel(notches)
        game.wheel(notches, platform.pointer.x, platform.pointer.y, platform.down)
        return true
    end
    -- The addon may hold the pointer on the bar for a drag, exactly as the game holds
    -- the pointer for its own scrollbar capture.
    function platform.hold_cursor(x, y)
        platform.pointer.x, platform.pointer.y = x, y
        return true
    end
    function platform.capture(center_x, center_y, options, strip_width, strip_window)
        local width = math.floor(strip_width or options.strip_width)
        local height = math.floor((strip_window or options.window) * 2)
        local origin_x = math.max(0, math.floor(center_x - width / 2))
        local origin_y = math.max(0, math.floor(center_y - height / 2))
        local scale = game.scale
        local thumb_top, thumb_height = game.thumb_top(), game.thumb_height()
        local pointer = {x = platform.pointer.x, y = platform.pointer.y}
        -- The measured pointer sprite: it hangs below and left of its hot spot.
        local function pointer_pixel(x, y)
            local dx, dy = x - pointer.x, y - pointer.y
            if dy >= 2 * scale and dy <= 26 * scale and dx >= -24 * scale and dx <= 3 * scale then
                if dy >= 6 * scale and dy <= 22 * scale and dx >= -21 * scale and dx <= -1 * scale then
                    return 235, 235, 235
                end
                return 200, 120, 60
            end
            return nil
        end
        local function content_pixel(screen_x, screen_y)
            -- Measured: spine 41 px left of the bar, the dim groove a dozen px, artwork 63 px.
            if screen_x >= game.column.x0 - game.spine - 1 and screen_x <= game.column.x0 - game.spine
                and screen_y >= game.list.y0 and screen_y <= game.list.y1 then
                return 165
            end
            if screen_x >= game.column.x0 - 14 * scale and screen_x <= game.column.x0 - 8 * scale
                and screen_y >= game.list.y0 and screen_y <= game.list.y1 then
                return 88
            end
            for _, row in ipairs({game.tab_row, game.sub_row}) do
                if screen_y >= row.y0 + 10 * scale and screen_y <= row.y1 - 10 * scale then
                    local centre = (game.grid.x0 + game.column.x0 - game.spine) / 2
                    local prompt = game.column.x0 - game.spine - 60 * scale
                    if math.abs(screen_x - centre) <= 90 * scale
                        or math.abs(screen_x - prompt) <= 45 * scale then
                        return 205
                    end
                end
            end
            if screen_y >= game.list.y0 and screen_y <= game.list.y1
                and screen_x >= game.grid.x0 and screen_x <= game.grid.x1 - 20 * scale then
                -- Item artwork inside the list.
                local tile = 180 * scale
                if math.floor((game.grid.x1 - screen_x) / tile) % 2 == 0 then return 150 end
                return 96
            end
            return nil
        end
        local function rgb(x, y)
            local screen_x, screen_y = origin_x + x, origin_y + y
            local r, g, b = pointer_pixel(screen_x, screen_y)
            if r then return r, g, b end
            -- A pixel is the bar when its centre falls inside the continuous
            -- column extent (the antialiased edge rule a real renderer uses).
            if screen_x + 0.5 >= game.column.x0 and screen_x + 0.5 <= game.column.x1
                and screen_y >= thumb_top and screen_y <= thumb_top + thumb_height then
                return 149, 149, 149
            end
            local bright = content_pixel(screen_x, screen_y)
            if bright then return bright, bright, bright end
            return 30, 30, 30
        end
        game.captures = game.captures + 1
        local width_cost = math.min(width, 240)
        local cost = CAPTURE_COST_MS + width_cost * height * PIXEL_COST_MS
        game.capture_ms = game.capture_ms + cost
        game.advance(math.floor(cost + 0.5))
        return {width = width, height = height, origin_x = origin_x, origin_y = origin_y, rgb = rgb}
    end
    return platform
end

local function boot(game, fallback)
    game.native_geometry = true
    game.route = game.route or 'grid'
    local platform = new_platform(game)
    -- Only the addon's writes can move the native model. The simulated game
    -- must not implement a working drag on the addon's behalf.
    game.key, game.writes = 'grid-1', 0
    -- The known game build (test_frame_budget.lua runs the real build gate).
    module.verify_build = function() return true end
    module.native_api = function() return {} end
    module.native_locate = function()
        if fallback or not game.key then return nil end
        return {key = game.key}
    end
    module.native_state = function(bridge)
        if not bridge or bridge.key ~= game.key then return nil end
        local model = {value = game.offset / game.travel, span = game.travel,
                content = game.content, viewport = game.content - game.travel,
                items = 80, columns = 4, rows = 5,
                first = math.floor(game.offset / 180) * 4, last = math.floor(game.offset / 180) * 4 + 20,
                anchor = math.floor(game.offset / 180)}
        if game.native_geometry then
            model.geometry = {left = game.column.x0, bottom = game.height - game.list.y1,
                width = game.column.x1 - game.column.x0, length = game.list.y1 - game.list.y0,
                thumb = game.thumb_height()}
            model.kind = game.route
            model.rendered_thumb = game.height - game.thumb_top() - game.thumb_height()
            if game.route == 'career' then model.first, model.last, model.anchor = nil, nil, nil end
        end
        return model
    end
    module.native_apply = function(bridge, model, value)
        assert(bridge.key == game.key, 'write through stale controller')
        game.writes = game.writes + 1
        if game.refuse_write then return nil, 'refused' end
        if not game.ignore_write then
            game.offset, game.target = value * model.span, value * model.span
        end
        return value
    end
    local environment = {update = function() end, shutdown = function() end,
                         CowboyBingusModLoader = {api = 1, open_log = function() return nil end}}
    local state = module.install(function() return platform end, environment)
    platform.environment = environment
    platform.state = state
    if game.native_geometry then
        function platform.viewport() return {x = 0, y = 0, height = game.height} end
    end
    return platform, state
end

local function tick(platform, milliseconds)
    platform.game.advance(milliseconds or FRAME_MS)
    platform.environment.update(0.016)
end

local function step(platform, x, y)
    platform.pointer.x, platform.pointer.y = x, y
    tick(platform)
end

local seed = 20260921
local function rnd(limit)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % limit
end

-- Helpers that describe a drag the way the user experiences it.
local function thumb_centre(game) return game.thumb_top() + game.thumb_height() / 2 end

-- The contract the live reports asked for: a held notch may only ever arrive with
-- the pointer over the bar's own column, and a click's notches only after release.
local function notches_on_the_bar(game, slack)
    for _, wheel in ipairs(game.wheels) do
        local on_bar = wheel.x >= game.column.x0 - slack and wheel.x <= game.column.x1 + slack
        if wheel.held and not on_bar then
            return false, string.format('held notch at %d,%d (column %d..%d)', wheel.x, wheel.y,
                game.column.x0, game.column.x1)
        end
    end
    return true
end

-- Grab the bar where the thumb is, the way a user starts a drag, and return the
-- pointer position that was pressed.
local function grab(platform, game)
    platform.pointer.y = thumb_centre(game)
    platform.down = true
    tick(platform)
    return platform.pointer.y
end

local function drag(platform, dy, frames, wander)
    local game = platform.game
    local x0, y0 = platform.pointer.x, platform.pointer.y
    for index = 1, frames do
        step(platform, x0 + (wander or 0) * (rnd(21) - 10) / 10, y0 + dy * index / frames)
    end
    for _ = 1, 30 do tick(platform) end
end

-- ------------------------------------------------------------- scenarios

print('simulator scenarios:')

-- 1. A drag through the middle of the list: the thumb has to travel as far as the
--    pointer does, with no end learned and no widget touched.
do
    local game = new_game({})
    local platform, state = boot(game)
    local start_thumb = thumb_centre(game)
    local start_pointer = grab(platform, game)
    drag(platform, -180, 45)
    platform.down = false
    tick(platform)
    local pointer_moved = start_pointer - platform.pointer.y
    local thumb_moved = start_thumb - thumb_centre(game)
    print(string.format('  mid-list drag %.0f px: thumb moved %.1f px (%.2f of the pointer), stalls=%d limits=%d',
        pointer_moved, thumb_moved, thumb_moved / pointer_moved, state.drag_stalls or 0, state.drag_limits or 0))
    check('a mid-list drag moves the thumb with the pointer',
        math.abs(thumb_moved - pointer_moved) <= 1.5 * game.thumb_step, thumb_moved .. '/' .. pointer_moved)
    check('a mid-list drag learns no end', (state.drag_stalls or 0) == 0 and (state.drag_limits or 0) == 0,
        tostring(state.drag_stalls) .. '/' .. tostring(state.drag_limits))
    check('a mid-list drag activates nothing', #game.activations == 0, table.concat(game.activations, ','))
    check('a mid-list drag stays inside the band', (state.drag_out or 0) == 0, tostring(state.drag_out))
    check('no capture is dumped to disk', (state.dumps or 0) == 0, tostring(state.dumps))
end

-- 2. Dragging up to the end of the list and past it, over the tab rows. The list
--    has to reach its end, the drag must not spend notches on the tabs above it,
--    and pulling back down has to move the thumb again straight away.
do
    local game = new_game({offset = 90})
    local platform, state = boot(game)
    grab(platform, game)
    local before = #game.wheels
    drag(platform, -700, 70)
    local after = #game.wheels
    check('a drag past the top reaches the top of the list', game.offset <= 4, game.offset)
    check('a drag past the top activates nothing', #game.activations == 0, table.concat(game.activations, ','))
    check('a drag past the top stops spending notches', after - before <= 16, after - before)
    check('a drag past the top keeps its notches on the bar', notches_on_the_bar(game, 6))
    -- Pull back down: the whole way back has to move the content again, and the
    -- distance the pointer went past the end is the only dead zone to unwind --
    -- exactly what dragging a native scrollbar past its end does.
    local from_offset = game.offset
    local before_back = #game.wheels
    local back_to = game.list.y0 + 320
    for index = 1, 40 do
        step(platform, platform.pointer.x, platform.pointer.y + (back_to - platform.pointer.y) / 8)
    end
    local after_back = #game.wheels
    game.advance(400)
    for _ = 1, 10 do tick(platform) end
    print(string.format('  drag past the top: offset %.0f -> %.0f, pull back moved %.1f px of content, stalls=%d',
        from_offset, game.offset, game.offset - from_offset, state.drag_stalls or 0))
    check('pulling back down moves the content again', game.offset > from_offset + 200,
        (after_back - before_back) .. '/' .. (game.offset - from_offset))
    check('pulling back down activates nothing', #game.activations == 0, table.concat(game.activations, ','))
    platform.down = false
    tick(platform)
end

-- 2b. The worst grab the live reports allow: the pointer takes the thumb's top
--     edge, so once the thumb is clamped at the top of the track the pointer is
--     already level with the list's first row.
do
    local game = new_game({offset = 60})
    local platform, state = boot(game)
    platform.pointer.y = game.thumb_top() + 4
    platform.down = true
    tick(platform)
    drag(platform, -60, 30)
    local after_short = game.offset
    drag(platform, -400, 40)
    for index = 1, 20 do
        step(platform, platform.pointer.x, platform.pointer.y + 18 * index)
    end
    drag(platform, -120, 30)
    platform.down = false
    tick(platform)
    print(string.format('  drag from the thumb\'s top edge: after 60 px=%.0f, after leaving and coming '
        .. 'back=%.0f, activations=%d (%s)', after_short, game.offset, #game.activations,
        table.concat(game.activations, ',')))
    check('a drag from the thumb edge activates nothing', #game.activations == 0,
        table.concat(game.activations, ','))
    check('a drag from the thumb edge scrolls a little', after_short < 40, after_short)
    check('a drag from the thumb edge keeps its notches on the bar', notches_on_the_bar(game, 6))
end

-- 2c. The live report, exactly: a fast drag that drifts 33 px left of the bar
--     while pushing past the top of the list. That is how a drag used to press
--     the Q/E and Z/C buttons above the list.
do
    local game = new_game({offset = 90})
    local platform, state = boot(game)
    platform.pointer.y = thumb_centre(game)
    platform.pointer.x = game.column.x0 + 4
    platform.down = true
    tick(platform)
    for index = 1, 60 do
        local drift = math.min(33, index) * game.scale
        step(platform, game.column.x0 + 4 - drift, platform.pointer.y - 9)
    end
    platform.down = false
    tick(platform)
    print(string.format('  fast drag with a 33 px left drift: offset=%.0f activations=%d (%s)', game.offset,
        #game.activations, table.concat(game.activations, ',')))
    check('a drifting drag activates nothing', #game.activations == 0, table.concat(game.activations, ','))
end

-- 2d. The reported sequence: hold the bar, drag off it somewhere else, release,
--     then come back and drag again. The second drag has to scroll.
do
    local game = new_game({offset = 500})
    local platform, state = boot(game)
    platform.pointer.y = thumb_centre(game)
    platform.down = true
    tick(platform)
    drag(platform, -60, 20)
    for index = 1, 25 do
        step(platform, game.column.x0 - 260, platform.pointer.y + 14)
    end
    platform.down = false
    tick(platform)
    local offset_off_bar = game.offset
    platform.pointer.x = game.column.x0 + 4
    platform.pointer.y = thumb_centre(game)
    platform.down = true
    tick(platform)
    local before = game.offset
    drag(platform, -120, 30)
    platform.down = false
    tick(platform)
    print(string.format('  hold, leave the bar, return: offset %.0f -> %.0f, second drag moved %.1f, thumb=%s',
        offset_off_bar, game.offset, before - game.offset, tostring(state.last_reason)))
    check('the second drag still scrolls after leaving the bar', before - game.offset > 60,
        before - game.offset)
end

-- 2e. The list moved behind the addon's back -- the player scrolled with the wheel,
--     which the addon never sees -- and the next press is then answered from a
--     stale model. The drag has to re-measure and still scroll.
do
    local game = new_game({offset = 1200})
    local platform, state = boot(game)
    grab(platform, game)
    platform.down = false
    tick(platform)
    for _ = 1, 6 do
        game.target = game.target - 60
        tick(platform)
    end
    for _ = 1, 20 do tick(platform) end
    platform.pointer.x = game.column.x0 + 4
    platform.pointer.y = thumb_centre(game) + 40
    platform.down = true
    tick(platform)
    local before = game.offset
    drag(platform, -180, 40)
    platform.down = false
    tick(platform)
    print(string.format('  drag after the game moved the list: moved %.1f px, resyncs=%d, limits=%d',
        before - game.offset, state.drag_resyncs or 0, state.drag_limits or 0))
    check('a drag after the list moved still scrolls', before - game.offset > 120, before - game.offset)
    check('a drag that leaves the thumb does not resync every frame', (state.drag_resyncs or 0) <= 1,
        tostring(state.drag_resyncs))
end

-- 3. The same at the bottom end of the list.
do
    local game = new_game({})
    local platform, state = boot(game)
    local travel = game.travel
    game.offset, game.target = travel - 90, travel - 90
    grab(platform, game)
    drag(platform, 700, 70)
    print(string.format('  drag past the bottom: offset=%.0f/%.0f stalls=%d activations=%d',
        game.offset, travel, state.drag_stalls or 0, #game.activations))
    check('a drag past the bottom reaches the end', travel - game.offset <= 4, game.offset)
    check('a drag past the bottom activates nothing', #game.activations == 0, table.concat(game.activations, ','))
    local from_offset = game.offset
    local back_to = game.list.y1 - 320
    for _ = 1, 40 do
        step(platform, platform.pointer.x, platform.pointer.y + (back_to - platform.pointer.y) / 8)
    end
    game.advance(400)
    for _ = 1, 10 do tick(platform) end
    check('pulling back up moves the content again', game.offset < from_offset - 200,
        game.offset - from_offset)
    platform.down = false
    tick(platform)
end

-- 4. A hand that wanders sideways: the pointer is held on the bar for the length of
--    the drag, the way a native scrollbar captures it, so the bar keeps following
--    and every notch still lands on the scrollbar rather than on what the hand
--    crossed.
do
    local game = new_game({})
    local platform, state = boot(game)
    local start_thumb = thumb_centre(game)
    grab(platform, game)
    local width = game.column.x1 - game.column.x0
    for index = 1, 30 do
        -- The hand drifts left the way a hand does, a few pixels at a time.
        step(platform, platform.pointer.x - 5, platform.pointer.y - 4)
    end
    local wandered = thumb_centre(game)
    check('a hand far off the bar keeps scrolling', start_thumb - wandered > 90, start_thumb - wandered)
    check('every held notch landed on the bar', notches_on_the_bar(game, 2))
    check('the wandering drag activates nothing', #game.activations == 0, table.concat(game.activations, ','))
    platform.down = false
    tick(platform)
end

-- 5. The interface is not at the scale the viewport suggests (the live report).
for _, case in ipairs({{scale = 1.5, reported = 1440}, {scale = 0.693, reported = 1440},
                      {scale = 1.0, reported = 998}}) do
    local game = new_game({scale = case.scale, reported_height = case.reported})
    local platform, state = boot(game)
    local thumb_before = thumb_centre(game)
    local pointer_before = grab(platform, game)
    local distance = math.floor(140 * case.scale)
    drag(platform, -distance, 40)
    local pointer_moved = pointer_before - platform.pointer.y
    local thumb_moved = thumb_before - thumb_centre(game)
    print(string.format('  interface %.3f reported as %d: ruler=%s, thumb %.1f px for %.1f px of pointer',
        case.scale, case.reported, state.ruler and string.format('%.3f', state.ruler) or 'none',
        thumb_moved, pointer_moved))
    check(string.format('scale %.3f with a %.0f px viewport is measured', case.scale, case.reported),
        game.captures == 0, 'native geometry must not require screenshot calibration')
    check(string.format('scale %.3f drag follows the pointer at that viewport', case.scale),
        math.abs(thumb_moved - pointer_moved) <= 2 * game.thumb_step, thumb_moved .. '/' .. pointer_moved)
    platform.down = false
    tick(platform)
end

-- 6. Hand jitter, randomised: 60 drags of random length, speed and wobble.
do
    local activations, worst, stalls, worst_round = 0, 0, 0, 0
    for round = 1, 60 do
        local game = new_game({})
        local platform, state = boot(game)
        local travel = game.travel
        game.offset, game.target = math.floor(travel / 2) + rnd(200) - 100, game.offset
        game.target = game.offset
        grab(platform, game)
        local offset_before = game.offset
        local direction = rnd(2) == 0 and -1 or 1
        local length, speed = 60 + rnd(300), 3 + rnd(12)
        local thumb_before = thumb_centre(game)
        local moved = 0
        local at_least, at_most = 0, 0
        while moved < length do
            local hop = math.min(speed, length - moved)
            local x = platform.pointer.x + rnd(9) - 4
            local y = platform.pointer.y + direction * hop
            -- The delivered movement has to sit between what the pointer made while it
            -- was over the bar's column and inside the list, and what it made anywhere
            -- the wheel can still reach the list: what happens at the ends, where the
            -- bar stops answering, is the addon's policy and is asserted elsewhere.
            local function inside(pad)
                return x >= game.column.x0 - pad and x <= game.column.x1 + pad
                    and y >= game.list.y0 and y <= game.list.y1
            end
            -- 5 bar widths is the band the drag keeps working inside, so movement
            -- made there is movement the list must have received.
            local band = math.floor(5 * (game.column.x1 - game.column.x0 + 1))
            local squarely, anywhere = inside(0), inside(band)
            step(platform, x, y)
            moved = moved + hop
            if squarely then at_least = at_least + hop end
            if anywhere then at_most = at_most + hop end
        end
        for _ = 1, 25 do tick(platform) end
        local thumb_moved = math.abs(thumb_centre(game) - thumb_before)
        -- The thumb follows the pointer one-to-one over the movement a wheel event
        -- could deliver, until the list runs out of content in that direction.
        local room = game.room
        local available = direction < 0 and (offset_before / travel) * room
            or ((travel - offset_before) / travel) * room
        local low, high = math.min(at_least, available), math.min(at_most, available)
        local error_px = math.max(low - thumb_moved, thumb_moved - high, 0)
        if error_px > worst then worst_round = round end
        if error_px > worst then worst = error_px end
        stalls = stalls + (state.drag_stalls or 0)
        activations = activations + #game.activations
        platform.down = false
        tick(platform)
    end
    print(string.format('  fuzz 60 drags: worst tracking error %.0f px (round %d), stalls=%d activations=%d',
        worst, worst_round, stalls, activations))
    check('no fuzzed drag activates a widget', activations == 0, activations)
    check('fuzzed drags track the pointer', worst <= 3 * REF.thumb_step, worst)
end

-- 7. The same drag at the three UI scales the addon is built for.
for _, scale in ipairs({0.693, 1.0, 1.5}) do
    local game = new_game({scale = scale})
    local platform, state = boot(game)
    local thumb_before = thumb_centre(game)
    local pointer_before = grab(platform, game)
    local distance = math.floor(160 * scale)
    drag(platform, -distance, 40)
    local pointer_moved = pointer_before - platform.pointer.y
    local thumb_moved = thumb_before - thumb_centre(game)
    print(string.format('  scale %.3f: thumb %.1f px for %.1f px of pointer, stalls=%d activations=%d',
        scale, thumb_moved, pointer_moved, state.drag_stalls or 0, #game.activations))
    check(string.format('scale %.3f drag follows the pointer', scale),
        math.abs(thumb_moved - pointer_moved) <= 2 * game.thumb_step, thumb_moved .. '/' .. pointer_moved)
    check(string.format('scale %.3f drag activates nothing', scale), #game.activations == 0,
        table.concat(game.activations, ','))
    platform.down = false
    tick(platform)
end

-- 8. Clicking the track beside the thumb still pages the list, and landing the
--    thumb under the pointer requires no capture.
do
    local game = new_game({})
    local platform, state = boot(game)
    local travel = game.travel
    game.offset, game.target = travel, travel
    local centre = thumb_centre(game)
    -- Land the pointer on the track high enough up that the thumb can actually
    -- be centred there (the top of the track clamps it otherwise).
    platform.pointer.y = game.list.y0 + 120
    platform.down = true
    tick(platform)
    for _ = 1, 12 do tick(platform) end
    local held_notches = #game.wheels
    platform.down = false
    tick(platform)
    for _ = 1, 10 do tick(platform) end
    print(string.format('  track click: offset %.0f -> %.0f, thumb centre %.1f -> %.1f, captures=%d',
        travel, game.offset, centre, thumb_centre(game), game.captures))
    check('a click sends nothing while the button is held', held_notches == 0, held_notches)
    check('a track click pages the list', travel - game.offset > 100, travel - game.offset)
    check('a track click lands the thumb under the pointer',
        math.abs(thumb_centre(game) - platform.pointer.y) <= 3 * game.thumb_step,
        thumb_centre(game) - platform.pointer.y)
    check('a track click activates nothing', #game.activations == 0, table.concat(game.activations, ','))
end

-- Fixed grab point, including verification, small moves, bounds and reversal.
do
    local game = new_game({})
    local platform, state = boot(game)
    local start = thumb_centre(game)
    grab(platform, game)
    local x, y = platform.pointer.x, platform.pointer.y
    step(platform, x, y + 80)
    for _ = 1, 20 do tick(platform) end
    step(platform, x, y + 81)
    check('verification cannot add the total displacement twice',
        math.abs(thumb_centre(game) - start - 81) < 2, thumb_centre(game) - start)
    local before = game.writes
    for _ = 1, 30 do tick(platform) end
    check('a stationary pointer produces no repeated writes', game.writes == before)
    step(platform, x - 200, game.tab_row.y0 + 10)
    check('native drag reaches the top over tabs without wheel input',
        game.offset == 0 and #game.wheels == 0 and #game.activations == 0)
    step(platform, x - 200, y)
    check('returning to the grab point restores the original scroll position',
        math.abs(thumb_centre(game) - start) < 2, thumb_centre(game) - start)
    platform.down = false
    tick(platform)
    check('native gesture reports no runtime errors', state.errors == 0, state.last_error)
end

do
    local game = new_game({})
    local platform, state = boot(game)
    grab(platform, game)
    local x, y = platform.pointer.x, platform.pointer.y
    for index = 1, 40 do step(platform, x, y + index / 4) end
    check('small native moves do not fall back just because the visible row is unchanged',
        not state.native_failed and #game.wheels == 0, state.last_reason)
    local before = game.writes
    game.key = 'grid-2'
    step(platform, x, y + 50)
    check('changing controllers cancels the gesture before any write',
        game.writes == before and state.errors == 0, state.last_error)
end

-- The fallback has no captured input target: never send held wheel input over
-- tabs or items, never retain a burst to emit after the mouse is released there.
do
    local game = new_game({})
    local platform, state = boot(game, true)
    grab(platform, game)
    local x, y = platform.pointer.x, platform.pointer.y
    step(platform, x, y - 30)
    local before = #game.wheels
    step(platform, game.grid.x1 - 10, game.tab_row.y0 + 20)
    step(platform, game.grid.x1 - 10, game.sub_row.y0 + 20)
    step(platform, game.grid.x1 - 10, y - 60)
    platform.down = false
    tick(platform)
    for _ = 1, 20 do tick(platform) end
    check('fallback never activates a tab or item during a wandering drag',
        #game.activations == 0, table.concat(game.activations, ','))
    check('fallback drops input while outside its scrollbar and on release', #game.wheels == before)
    check('unsupported owners stay inert without a screenshot fallback',
        before == 0 and game.captures == 0 and game.offset == game.travel / 2)
end

do
    local game = new_game({})
    local platform, state = boot(game)
    platform.pointer.y = game.thumb_top() + 20
    local y, offset = platform.pointer.y, game.offset
    platform.down = true
    tick(platform)
    for _ = 1, 20 do tick(platform) end
    platform.down = false
    tick(platform)
    check('clicking a thumb off-centre does not jump on press or release',
        game.writes == 0 and #game.wheels == 0 and game.offset == offset)
    platform.pointer.y = game.list.y0 + 40
    platform.down = true
    tick(platform)
    local after = game.offset
    step(platform, platform.pointer.x, platform.pointer.y + 140)
    check('a native track click continues smoothly into a drag', game.offset > after + 100 and #game.wheels == 0)
    local before = game.writes
    platform.focused = false
    step(platform, platform.pointer.x, y)
    platform.focused = true
    step(platform, platform.pointer.x, y + 50)
    check('focus loss cancels native ownership until a fresh press', game.writes == before and not state.drag_active)
end

do
    local game = new_game({})
    local platform, state = boot(game)
    game.ignore_write = true
    grab(platform, game)
    step(platform, platform.pointer.x, platform.pointer.y + 90)
    for _ = 1, 30 do tick(platform) end
    check('an ignored native write is verified even after the pointer stops', state.native_failed == true)
    check('native failure never changes to wheel input during the same hold', #game.wheels == 0)
    local before = game.writes
    platform.down = false
    tick(platform)
    platform.pointer.y = thumb_centre(game)
    platform.down = true
    tick(platform)
    step(platform, platform.pointer.x, platform.pointer.y + 20)
    check('a retired controller stays retired when rediscovered', game.writes == before)
end

for _, lose_focus in ipairs({false, true}) do
    local game = new_game({})
    local platform, state = boot(game, true)
    platform.pointer.y = game.list.y0 + 20
    platform.down = true
    tick(platform)
    platform.down = false
    tick(platform)
    check('fallback waits for the game to consume mouse-up before sending a track click', #game.wheels == 0)
    if lose_focus then platform.focused = false
    else platform.pointer.x, platform.pointer.y = game.grid.x1 - 10, game.tab_row.y0 + 20 end
    for _ = 1, 20 do tick(platform) end
    check('a queued click cannot follow the pointer or focus to a different target', #game.wheels == 0)
end

do
    local game = new_game({})
    local platform, state = boot(game)
    state.settings.native, state.base_settings.native = 0, 0
    platform.pointer.y = game.list.y0 + 20
    platform.down = true
    tick(platform)
    check('native=0 disables native track clicks as well as dragging', game.writes == 0)
end

for _, route in ipairs({'grid', 'career'}) do
    local game = new_game({content = route == 'career' and 1315 or nil})
    game.native_geometry, game.route = true, route
    local platform, state = boot(game)
    local before = thumb_centre(game)
    local y = game.thumb_top() + 15 -- preserve an off-centre grab point
    platform.pointer.y, platform.down = y, true
    tick(platform)
    for _, x in ipairs({-1200, 0, 750, 2500, 5000}) do
        step(platform, x, y + 50)
        for _ = 1, 16 do tick(platform) end
        check(route .. ' follows vertical movement at horizontal x=' .. x,
            math.abs(thumb_centre(game) - before - 50) < 0.01 and not state.native_failed)
    end
    step(platform, game.grid.x1 - 10, game.tab_row.y0)
    check(route .. ' reaches the top across tabs', game.offset == 0)
    step(platform, -1200, game.list.y1 + 600)
    check(route .. ' clamps at the bottom regardless of horizontal position', game.offset == game.travel)
    step(platform, 5000, y)
    check(route .. ' reverses to the original grab position', math.abs(thumb_centre(game) - before) < 0.01)
    check(route .. ' captured drag emits no wheel events or widget activations',
        #game.wheels == 0 and #game.activations == 0 and game.captures == 0)
    platform.down = false
    tick(platform)
    local writes = game.writes
    step(platform, 0, y + 100)
    check(route .. ' releases ownership on mouse-up', game.writes == writes and not state.drag_active)
    platform.pointer.x, platform.pointer.y = game.column.x0 + 2, y
    platform.down = true
    tick(platform)
    game.route = 'changed-menu'
    step(platform, 0, y + 100)
    check(route .. ' cancels before writing into a changed menu', game.writes == writes and state.errors == 0)
end

print(string.format('ui simulator: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
