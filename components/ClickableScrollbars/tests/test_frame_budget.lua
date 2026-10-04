-- Per-frame calls, pinned with tests/frame_budget.lua (canonical copy:
-- PerformanceBaseline/frame_budget.lua; keep the copies byte-identical).
--
-- The real addon runs whole frames on each route it drives. Its shipped reader
-- reads this process with ReadProcessMemory: each menu is built in memory owned
-- by this test, and the five game routines are machine-code stubs at their game
-- RVAs inside a reserved fake game.dll. The real platform runs on fake Windows
-- functions. One budget per frame counts the reader's calls (read, pointer,
-- module = GetModuleHandleA), the game routines (stop, scroll, position, solve,
-- consume) and the Windows calls by name. In game a ReadProcessMemory costs
-- about 1-2 us; the other Windows calls and the game routines are unmeasured.

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local ffi = require('ffi')
local module = assert(loadfile(assert(arg[2])))()
local directory = assert(arg[0]:match('^(.*)[/\\]'))
local budget = dofile(directory .. '/frame_budget.lua')
local PRINT = arg[3] == '--print'

ffi.cdef [[
    void *hd2cs_test_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect) __asm__("VirtualAlloc");
    int hd2cs_test_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')

-- ------------------------------------------------------------ the fake game

-- Game RVAs the addon reads or calls. The image is reserved whole and only these
-- pages are committed. Stubs: the scroll setter stores its value at bar + 1976
-- (the scrollbar's value field), the position setter stores x and y at +4 and
-- +8; the solver, the animation stop and the input consume only return.
local RVA = {solver = 0x18d2b60, scroll = 0x1794530, position = 0x14476a0, stop = 0x1439d40,
             consume = 0x12fde90, dispatch = 0x3326e68, stack = 0x347ce28, menu = 0x347ce38,
             input = 0x347cf18}
local STUBS = {scroll = 'F30F1189B8070000C3', position = '48895104C3', solver = 'C3', stop = 'C3', consume = 'C3'}
local IMAGE_BYTES = 0x3480000
local image_base = kernel.hd2cs_test_VirtualAlloc(nil, IMAGE_BYTES, 0x2000, 0x01)
assert(image_base ~= nil, 'fake image reservation failed')
local image = ffi.cast('uint8_t *', image_base)
for name, rva in pairs(RVA) do
    local page = image + (rva - rva % 0x1000)
    assert(kernel.hd2cs_test_VirtualAlloc(page, 0x1000, 0x1000, 0x40) ~= nil, 'commit failed: ' .. name)
    local index = 0
    for pair in (STUBS[name] or ''):gmatch('%x%x') do
        image[rva + index] = tonumber(pair, 16)
        index = index + 1
    end
end

local u32p, f32p, u64p = ffi.typeof('uint32_t *'), ffi.typeof('float *'), ffi.typeof('uint64_t *')
-- Stores into the fake game memory this test owns.
local function put_u32(base, offset, value)
    ffi.cast(u32p, base + offset)[0] = value -- lint-ok: R3 test only: the test's own fake game memory
end
local function put_f32(base, offset, value)
    ffi.cast(f32p, base + offset)[0] = value -- lint-ok: R3 test only: the test's own fake game memory
end
local function put_pointer(base, offset, target)
    local bits = type(target) == 'number' and target or ffi.cast('uintptr_t', target)
    ffi.cast(u64p, base + offset)[0] = bits -- lint-ok: R3 test only: the test's own fake game memory
end

-- A scrollbar widget: height, width, resolved alpha, UI scale, left, bottom.
local function widget(base, offset, height, width, alpha, left, bottom)
    put_f32(base, offset + 16, height); put_f32(base, offset + 12, width); put_f32(base, offset + 84, alpha)
    put_f32(base, offset + 100, 4 / 3); put_f32(base, offset + 140, 4 / 3)
    put_f32(base, offset + 148, left); put_f32(base, offset + 156, bottom)
end

local GRID_OFFSET, LOADOUT_OFFSET, PANEL = 523752, 864032, 318472

local function fill_grid(grid)
    put_u32(grid, 597772, 5); put_u32(grid, 47540, 4); put_u32(grid, 600452, 80)
    put_u32(grid, 600308, 0); put_u32(grid, 602052, 4)
    put_f32(grid, 600424, 4018); put_f32(grid, 0x8C0, 3000); put_f32(grid, 0x8C8, 0.5)
    put_f32(grid, 600416, 1500)
    widget(grid, 272, 738, 7, 1, 1528, 138)
    widget(grid, 888, 134.87964, 7, 1, 1528, 600)
end

-- The game's part of each frame: the grid solver derives the visible range and
-- the rendered thumb from the scroll offset; Career derives its thumb from the
-- container position. Pointers are cast once, so the game allocates nothing.
local function grid_solver(grid)
    local scroll, value = ffi.cast(f32p, grid + 600416), ffi.cast(f32p, grid + 0x8C8)
    local first, last = ffi.cast(u32p, grid + 622656), ffi.cast(u32p, grid + 622660)
    local anchor, rendered = ffi.cast(u32p, grid + 602096), ffi.cast(f32p, grid + 888 + 156)
    return function()
        local row = math.floor(scroll[0] / 200)
        first[0], last[0], anchor[0] = row * 4, row * 4 + 20, row
        rendered[0] = 138 + (1 - value[0]) * 603
    end
end

local function career_update(panel)
    local y, rendered = ffi.cast(f32p, panel + 2488 + 8), ffi.cast(f32p, panel + 195808 + 156)
    return function() rendered[0] = 434 + (y[0] + 4) * 0.5 end
end

-- One menu on screen: 'grid' (Armory, kind 224), 'loadout' (kind 229 under
-- screen state 14), 'career' (the Armory's Career panel), 'bindings' (screen 26)
-- or 'settings' (screen 1).
local function new_world(route)
    local world = {route = route, blocks = {}}
    local function block(bytes)
        local memory = ffi.new('uint8_t[?]', bytes)
        world.blocks[#world.blocks + 1] = memory
        return ffi.cast('uint8_t *', memory)
    end
    local dispatch, owner, menu, input = block(8192), block(0x4400), block(512), block(64)
    put_pointer(image, RVA.dispatch, dispatch); put_pointer(image, RVA.stack, owner)
    put_pointer(image, RVA.menu, menu); put_pointer(image, RVA.input, input)
    world.dispatch, world.owner, world.menu, world.block = dispatch, owner, menu, block
    local rows, top = {}, 5
    if route == 'grid' or route == 'career' then
        local controller = block(GRID_OFFSET + 622700)
        world.grid, world.panel = controller + GRID_OFFSET, controller + PANEL
        fill_grid(world.grid)
        local career = route == 'career' and 1 or 0
        widget(world.panel, 195256, 762, 10, career, 1528, 128)
        widget(world.panel, 195808, 439, 10, career, 1528, 434)
        put_f32(world.panel, 2488 + 16, 1315); put_f32(world.panel, 2488 + 32, 1)
        put_f32(world.panel, 2488 + 4, 0); put_f32(world.panel, 2488 + 8, 320)
        world.update = route == 'career' and career_update(world.panel) or grid_solver(world.grid)
        rows = {{0x1111111, 12}, {controller, 224}, {0x2222222, 7}}
    elseif route == 'loadout' then
        local controller = block(LOADOUT_OFFSET + 622700)
        world.grid = controller + LOADOUT_OFFSET
        fill_grid(world.grid)
        world.update = grid_solver(world.grid)
        rows, top = {{0x1111111, 12}, {controller, 229}}, 14
    else
        local settings = route == 'settings'
        local list_offset = settings and 4189984 or 338344
        local screen = block(list_offset + 3000)
        put_pointer(menu, settings and 200 or 208, screen)
        screen[12] = 1
        local list = screen + list_offset
        world.list, world.screen = list, screen
        widget(list, 816, 806, 6, 1, 1668.667, 117.333)
        widget(list, 1432, 198.3, 6, 1, 1668.667, 544.444)
        put_f32(list, 552, 1168); put_f32(list, 2784, 2470); put_f32(list, 2792, 0.473)
        world.update = function() end
        rows, top = {{0x1111111, 67}}, settings and 1 or 26
    end
    put_u32(dispatch, 5740, #rows)
    for index, row in ipairs(rows) do
        local offset = 5744 + (index - 1) * 16
        put_pointer(dispatch, offset, row[1])
        put_u32(dispatch, offset + 8, row[2])
        put_u32(dispatch, offset + 12, 0)
    end
    put_u32(owner, 0x429c, top)
    put_u32(owner, 0x429c + 20, 1)
    return world
end

-- ------------------------------------------------------- the counted addon

local PID, WINDOW = 4242, 0x1234

-- Fake Windows functions for the real platform, one table for both libraries.
local function new_windows(input)
    return {
        GetTickCount64 = function() return input.now end,
        GetCurrentProcessId = function() return PID end,
        GetAsyncKeyState = function(key) return key == 0x01 and input.down and -32768 or 0 end,
        GetForegroundWindow = function() return WINDOW end,
        GetWindowThreadProcessId = function(_, process) process[0] = PID; return 1 end,
        GetCursorPos = function(point) point[0].x, point[0].y = input.x, input.y; return 1 end,
        GetClientRect = function(_, rect)
            rect[0].left, rect[0].top, rect[0].right, rect[0].bottom = 0, 0, 2560, 1440
            return 1
        end,
        ClientToScreen = function() return 1 end,
        IsWindow = function() return 1 end,
        GetSystemMetrics = function() return 1440 end,
    }
end

-- A platform of plain Lua functions, for the interpreted garbage measurement:
-- only the addon's own allocations count.
local function plain_platform(input)
    return {
        now = function() return input.now end,
        pressed = function() return input.down end,
        key_state = function() return input.down and 0x8000 or 0 end,
        foreground_self = function() return true end,
        cursor = function() return input.x, input.y end,
        viewport = function() return {x = 0, y = 0, width = 2560, height = 1440} end,
        display_height = function() return 1440 end,
        close = function() end,
    }
end

-- The addon installed on one world. Every call it makes is counted. With
-- plain, it runs on plain_platform instead of the real platform.
local function new_session(route, plain)
    local world = new_world(route)
    local input = {now = 1000, down = false, x = 200, y = 600}
    local windows = new_windows(input)
    local counted = {}
    module.native_api = function()
        local api = module.native_reader()
        api.module = function(name)
            if name == 'game.dll' then return ffi.cast('uint8_t *', image) end
        end
        counted[#counted + 1] = budget.wrap(api)
        return api
    end
    local environment = {update = function() world.update() end, shutdown = function() end,
                         CowboyBingusModLoader = {api = 1, open_log = function() return nil end}}
    counted[#counted + 1] = budget.wrap(windows)
    local libraries = {user32 = windows, kernel32 = windows}
    local function platform()
        if plain then return plain_platform(input) end
        return module.create_platform(libraries)
    end
    local state = assert(module.install(platform, environment))
    counted[#counted + 1] = budget.wrap(module.native_calls({game = image}))
    -- Screen positions of the thumb and the track, from an uncounted reader.
    local plain = module.native_reader()
    plain.module = function() return ffi.cast('uint8_t *', image) end
    local model = assert(module.native_state(assert(module.native_locate(plain))))
    local track = assert(module.native_screen_track(model, {x = 0, y = 0, height = 1440}))
    local thumb_top = track.top + model.value * track.span
    local session = {world = world, input = input, state = state, environment = environment,
                     x = math.floor((track.left + track.right) / 2),
                     thumb_y = math.floor(thumb_top + track.thumb / 2), track_y = math.floor(track.top + 10)}
    -- One game update.
    function session.update()
        input.now = input.now + 16
        environment.update(1 / 60)
    end
    -- One game update, returning the calls it made by name.
    function session.frame()
        for _, counts in ipairs(counted) do
            for name in pairs(counts) do counts[name] = nil end
        end
        input.now = input.now + 16
        environment.update(1 / 60)
        local frame = {}
        for _, counts in ipairs(counted) do
            for name, n in pairs(counts) do frame[name] = n end
        end
        return frame
    end
    return session
end

-- ------------------------------------------------------------------ budgets

-- Sums call counts.
local function add(...)
    local out = {}
    for index = 1, select('#', ...) do
        for name, n in pairs((select(index, ...))) do out[name] = (out[name] or 0) + n end
    end
    return out
end

-- Windows calls. Every frame reads the button; without diagnostics nothing else
-- runs on a frame with no gesture and no press (was 5 calls: the clock twice
-- and the foreground window and its process as well).
local EVERY = {GetAsyncKeyState = 1}
-- A frame with a gesture or a press asks for the foreground window and its process.
local FOCUS = add(EVERY, {GetForegroundWindow = 1, GetWindowThreadProcessId = 1})
-- A held gesture also reads the clock and the cursor.
local HELD = add(FOCUS, {GetTickCount64 = 1, GetCursorPos = 1})
-- A press reads the clock, the viewport (its window, client rectangle and
-- origin) and the cursor; it no longer asks for the focus a second time.
local PRESS = add(FOCUS, {GetTickCount64 = 1, GetForegroundWindow = 1, GetClientRect = 1, ClientToScreen = 1,
                          GetCursorPos = 1})
-- A settings press consumes the UI selection: it reads the input owner's
-- pointer and decodes it. While the gesture holds the selection (until
-- mouse-up), each frame checks the foreground again, reads the pointer (decoded
-- again only if it changed) and consumes the selection.
local CONSUME_ON_PRESS = {read = 1, pointer = 1, consume = 1}
local HOLD_SELECTION = {GetForegroundWindow = 1, GetWindowThreadProcessId = 1, read = 1, consume = 1}

-- The game routines a drag write calls, per route.
local WRITE = {
    grid = {stop = 1, scroll = 1, solve = 1}, loadout = {stop = 1, scroll = 1, solve = 1},
    career = {position = 1}, bindings = {scroll = 1, position = 1}, settings = {scroll = 1, position = 1},
}

-- Resolving the owner on a press: registry rows and pointers as strings, the row
-- count and visibility into the memory view's buffers, pointer decodes and the
-- game.dll handle. Its reads are recorded.
local OWNER = {
    grid = {read = 2, read_into = 3, pointer = 2, module = 1},
    loadout = {read = 4, read_into = 2, pointer = 3, module = 1},
    career = {read = 2, read_into = 2, pointer = 2, module = 1},
    bindings = {read = 7, read_into = 2, pointer = 4, module = 1},
    settings = {read = 7, read_into = 2, pointer = 4, module = 1},
}
-- A held frame repeats exactly those reads (as string reads) instead of
-- resolving again: no handle, no pointer decode.
local REPEAT = {grid = {read = 5}, loadout = {read = 6}, career = {read = 4}, bindings = {read = 9},
                settings = {read = 9}}
-- The list's model, in blocks: 4 for a grid, 2 for Career, 1 for an options list.
local MODEL = {grid = {read_into = 4}, loadout = {read_into = 4}, career = {read_into = 2},
               bindings = {read_into = 1}, settings = {read_into = 1}}

local function limits(route, frame)
    local owner, again, model, write = OWNER[route], REPEAT[route], MODEL[route], WRITE[route]
    local settings = route == 'settings'
    local held = add(HELD, again, model, settings and HOLD_SELECTION or {})
    local press = add(PRESS, owner, model, settings and CONSUME_ON_PRESS or {})
    local budgets = {
        ['idle'] = EVERY, ['hover'] = EVERY, ['after release'] = EVERY,
        ['press thumb'] = press,
        ['held still'] = held,
        ['held moving'] = add(held, write),
        -- The first write is checked against the game's read-back once: one more model read.
        ['held verification'] = add(held, write, model),
        -- A release ends the gesture without the clock.
        ['release'] = add(FOCUS, settings and HOLD_SELECTION or {}),
        -- A track press resolves, then writes on the same frame as a held drag does.
        ['press track'] = add(press, again, model, write),
    }
    return assert(budgets[frame], 'no budget for ' .. frame)
end

-- --------------------------------------------------------------- scenarios

local checked = 0
local function expect(route, label, frame)
    if PRINT then print(string.format('  %-8s %-18s %s', route, label, budget.describe(frame))) return end
    budget.check(frame, limits(route, label), route .. ' ' .. label)
    checked = checked + 1
end

for _, route in ipairs({'grid', 'loadout', 'career', 'bindings', 'settings'}) do
    local s = new_session(route)
    local input = s.input
    for _ = 1, 3 do s.frame() end
    expect(route, 'idle', s.frame())
    input.x, input.y = s.x, s.thumb_y
    s.frame()
    expect(route, 'hover', s.frame())
    input.down = true
    expect(route, 'press thumb', s.frame())
    expect(route, 'held still', s.frame())
    input.y = input.y + 1
    expect(route, 'held moving', s.frame())
    -- The verification falls on the first frame at least native_verify_ms after the press.
    local verified = false
    for _ = 1, 20 do
        input.y = input.y + 1
        local frame = s.frame()
        if not verified and s.state.native_ok == 1 then
            verified = true
            expect(route, 'held verification', frame)
        end
    end
    assert(verified and not s.state.native_failed, route .. ': the drag was not verified')
    input.y = input.y + 1
    expect(route, 'held moving', s.frame())
    expect(route, 'held still', s.frame())
    input.down = false
    expect(route, 'release', s.frame())
    expect(route, 'after release', s.frame())
    input.y = s.track_y
    s.frame()
    input.down = true
    expect(route, 'press track', s.frame())
    input.down = false
    s.frame()
    assert(s.state.errors == 0, route .. ': ' .. tostring(s.state.last_error))
    assert(s.state.drags == 2 and s.state.pages == 1, route .. ': gestures not completed')
end

-- ------------------------------------------------- garbage per held frame

-- A held drag frame allocates nothing: the owner is re-validated by repeating
-- recorded reads (unchanged bytes come back as the interned strings) and the
-- model is read into a reused table. Measured with the collector stopped:
-- - interpreted (the JIT off while measuring), on plain_platform, as the
--   difference of two windows so that the measurement's own cost cancels: a
--   still pointer allocates nothing; a moving one allocates only the cdata the
--   game routine wrappers box (the grid's float store; Career's and the options
--   lists' packed position vector);
-- - with the JIT on, on the real platform and fake Windows functions: the same.
--   The native layer stays interpreted (keep_interpreted), so the wrappers box
--   in game as well. Every trace the JIT compiles is a 1-2 KB object in the same
--   heap, so one loop (window_bytes) serves the warm-up and every window, and
--   each verdict is the median of WINDOWS windows, which one-off JIT work cannot
--   move, plus their total, which catches a table that grows only now and then.
--   The frames run from an interpreted driver, as the engine calls the game's
--   update; a traced driver would only abort on the interpreted frame. There is
--   no round after jit.flush() here (test_platform.lua has one for the per-frame
--   query): after a flush the platform's cursor query runs interpreted, two
--   16-byte struct references per call, until its trace compiles again, which
--   took up to 4,000 frames, more than these windows hold.
local MOVING_INTERPRETED = {grid = 16, loadout = 16, career = 48, bindings = 48, settings = 48}
local jit_library = rawget(_G, 'jit')

local function held_session(route, plain)
    local s = new_session(route, plain)
    s.input.x, s.input.y = s.x, s.thumb_y
    s.update()
    s.input.down = true
    s.update()
    for _ = 1, 20 do s.input.y = s.input.y + 1; s.update() end
    assert(s.state.native_ok == 1 and s.state.drag_active, route .. ': no verified drag to measure')
    local y = s.input.y
    local function still() s.update() end
    local function moving()
        s.input.y = s.input.y == y and y + 1 or y
        s.update()
    end
    return s, still, moving
end

local function window_bytes(step, frames)
    collectgarbage('collect'); collectgarbage('stop') -- lint-ok: R4 test only: counts garbage, GC held
    local before = collectgarbage('count')
    for _ = 1, frames do step() end
    local bytes = (collectgarbage('count') - before) * 1024
    collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped above
    return bytes
end

if jit_library then jit_library.off(window_bytes) end

local function per_frame(step)
    return (window_bytes(step, 400) - window_bytes(step, 200)) / 200
end

-- Seven windows, as a late side trace (about 1 KB) can land in any of them
-- and a median of seven ignores three. The median has 0.5 bytes per frame of
-- slack, which a steady leak exceeds in every window; the total has 16 KB,
-- which a table growing by a slot every few frames exceeds in its doubling
-- bursts.
local WINDOWS, FRAMES, WARM_WINDOWS = 7, 2000, 2

local function compiled_round(step, budget, label)
    for _ = 1, WARM_WINDOWS do window_bytes(step, FRAMES) end -- warm-up: the same loop
    local sizes, sorted, total = {}, {}, 0
    for index = 1, WINDOWS do
        sizes[index] = window_bytes(step, FRAMES)
        sorted[index], total = sizes[index], total + sizes[index]
    end
    table.sort(sorted)
    local median = sorted[(WINDOWS + 1) / 2]
    local parts = {}
    for index, bytes in ipairs(sizes) do parts[index] = string.format('%.0f', bytes) end
    assert(median <= budget * FRAMES + 1024 and total <= budget * FRAMES * WINDOWS + 16 * 1024,
        string.format('%s: windows of %d frames allocated %s bytes (budget %d B per frame)', label, FRAMES,
            table.concat(parts, ' '), budget))
end

local held_checked = 0
if jit_library then
    jit_library.off() -- lint-ok: R5 test only: measures the interpreter
    jit_library.flush() -- lint-ok: R5 test only: starts the interpreted measurement without traces
end
for _, route in ipairs({'grid', 'loadout', 'career', 'bindings', 'settings'}) do
    local s, still, moving = held_session(route, true)
    local writes = s.state.native_writes
    local still_bytes, moving_bytes = per_frame(still), per_frame(moving)
    assert(s.state.native_writes > writes and s.state.drag_active and s.state.errors == 0, route .. ': drag ended')
    assert(still_bytes == 0, string.format('%s: a still held frame allocated %.1f B interpreted', route, still_bytes))
    assert(moving_bytes <= MOVING_INTERPRETED[route], string.format('%s: a moving held frame allocated %.1f B '
        .. 'interpreted, budget %d', route, moving_bytes, MOVING_INTERPRETED[route]))
    held_checked = held_checked + 2
end
if jit_library then
    jit_library.on() -- lint-ok: R5 test only: restores the JIT
    for _, route in ipairs({'grid', 'loadout', 'career', 'bindings', 'settings'}) do
        local s, still, moving = held_session(route, false)
        jit_library.off(still); jit_library.off(moving); jit_library.off(s.update)
        for _, case in ipairs({{'still', still, 0}, {'moving', moving, MOVING_INTERPRETED[route]}}) do
            compiled_round(case[2], case[3], route .. ' ' .. case[1])
            held_checked = held_checked + 1
        end
        assert(s.state.drag_active and s.state.errors == 0, route .. ': drag ended')
    end
end

-- ----------------------------------------------- garbage per release frame

-- Releasing a drag that wrote allocates nothing, interpreted (on
-- plain_platform) and with the JIT on (on the real platform): the release
-- trace formats its value only when diagnostics keep it. Before, every release
-- formatted it for a trace that was then dropped: a 28 B string in the
-- workspace LuaJIT; in lua51.dll a 23 B string, plus 256 B to grow the
-- formatting buffer again after each collection had shrunk it (279 B in these
-- windows, which start with a collection). Each release is one measured window
-- of one frame; the verdict is the median of RELEASES windows, which a trace
-- compiled inside one of them cannot move.
local RELEASES = 9
local function release_bytes(s)
    local writes = s.state.native_writes or 0
    s.input.x, s.input.y = s.x, s.thumb_y
    s.update()
    s.input.down = true
    s.update()
    for _ = 1, 3 do s.input.y = s.input.y + 1; s.update() end
    assert(s.state.drag_active and s.state.native_writes > writes, 'no written drag to release')
    s.input.down = false
    local bytes = window_bytes(s.update, 1)
    assert(not s.state.drag_active and s.state.errors == 0, 'the release frame did not end the drag cleanly')
    s.update()
    return bytes
end
local released = 0
local function release_round(plain, label)
    for _, route in ipairs({'grid', 'loadout', 'career', 'bindings', 'settings'}) do
        local s = new_session(route, plain)
        local sizes, sorted = {}, {}
        for index = 1, RELEASES do
            sizes[index] = release_bytes(s)
            sorted[index] = sizes[index]
        end
        table.sort(sorted)
        local parts = {}
        for index, bytes in ipairs(sizes) do parts[index] = string.format('%.0f', bytes) end
        assert(sorted[(RELEASES + 1) / 2] == 0, string.format('%s %s: release frames allocated %s bytes', route, label,
            table.concat(parts, ' ')))
        released = released + 1
    end
end
if jit_library then
    jit_library.off() -- lint-ok: R5 test only: measures the interpreter
    jit_library.flush() -- lint-ok: R5 test only: starts the interpreted measurement without traces
end
release_round(true, 'interpreted')
if jit_library then
    jit_library.on() -- lint-ok: R5 test only: restores the JIT
    release_round(false, 'compiled')
end

-- ------------------------------------------------ held drag re-validation

-- A held drag repeats the reads that resolved its owner and re-reads the model,
-- on the shipped reader. Each change below lands between two held frames; the
-- drag must cancel before writing again when the list is no longer the one
-- grabbed, and keep going when the owner is merely re-resolved (its reads
-- changed, the decision did not).
local function moved_block(world, field, bytes, slot)
    local copy = world.block(bytes)
    ffi.copy(copy, world[field], bytes)
    world[field] = copy
    put_pointer(image, slot, copy)
end
local GRID_CASES = {
    {'the controller leaves the registry', 'cancel', function(w) put_u32(w.dispatch, 5744 + 16 + 8, 7) end},
    {'another category opens', 'cancel', function(w) put_u32(w.grid, 600452, 81) end},
    {'the content grows', 'cancel', function(w) put_f32(w.grid, 600424, 4019) end},
    {'the span changes', 'cancel', function(w) put_f32(w.grid, 0x8C0, 2990) end},
    {'the layout kind changes', 'cancel', function(w) put_u32(w.grid, 602052, 5) end},
    {'the scrollbar is hidden', 'cancel', function(w) put_f32(w.grid, 272 + 84, 0) end},
    {'the column count goes out of range', 'cancel', function(w) put_u32(w.grid, 47540, 0) end},
    {'the registry is reallocated', 'continue', function(w) moved_block(w, 'dispatch', 8192, RVA.dispatch) end},
    {'the scrollbar fades but stays visible', 'continue', function(w) put_f32(w.grid, 272 + 84, 0.99) end},
    {'the content moves by a rounding error', 'continue', function(w) put_f32(w.grid, 600424, 4018.05) end},
}
local CASES = {
    grid = {
        {'the Career panel opens over the grid', 'cancel', function(w)
            put_f32(w.panel, 195256 + 84, 1); put_f32(w.panel, 195808 + 84, 1)
        end},
        {'a registry row is added after the controller', 'continue', function(w)
            put_u32(w.dispatch, 5740, 4)
        end},
    },
    loadout = {
        {'another screen goes on top', 'cancel', function(w) put_u32(w.owner, 0x429c, 26) end},
        {'the screen stack is reallocated', 'continue', function(w) moved_block(w, 'owner', 0x4400, RVA.stack) end},
    },
    career = {
        {'the Career panel closes', 'cancel', function(w)
            put_f32(w.panel, 195256 + 84, 0); put_f32(w.panel, 195808 + 84, 0)
        end},
        {'the Career list grows', 'cancel', function(w) put_f32(w.panel, 2488 + 16, 1316) end},
        {'the controller leaves the registry', 'cancel', function(w) put_u32(w.dispatch, 5744 + 16 + 8, 7) end},
        {'the registry is reallocated', 'continue', function(w) moved_block(w, 'dispatch', 8192, RVA.dispatch) end},
    },
    bindings = {
        {'another screen goes on top', 'cancel', function(w) put_u32(w.owner, 0x429c, 1) end},
        {'the page closes', 'cancel', function(w) w.screen[12] = 0 end},
        {'the scrollbar is hidden', 'cancel', function(w) put_f32(w.list, 816 + 84, 0) end},
        {'the list grows', 'cancel', function(w) put_f32(w.list, 2784, 2471) end},
        {'an equipment controller registers', 'cancel', function(w) put_u32(w.dispatch, 5744 + 8, 229) end},
        {'the menu is reallocated', 'continue', function(w) moved_block(w, 'menu', 512, RVA.menu) end},
    },
}
for _, case in ipairs(GRID_CASES) do
    table.insert(CASES.grid, case)
    table.insert(CASES.loadout, case)
end
CASES.settings = {
    {'another screen goes on top', 'cancel', function(w) put_u32(w.owner, 0x429c, 26) end},
    {'the page closes', 'cancel', function(w) w.screen[12] = 0 end},
    {'the menu is reallocated', 'continue', function(w) moved_block(w, 'menu', 512, RVA.menu) end},
}

local held_cases = 0
for _, route in ipairs({'grid', 'loadout', 'career', 'bindings', 'settings'}) do
    for _, case in ipairs(CASES[route]) do
        local s = held_session(route, true)
        local state, input = s.state, s.input
        case[3](s.world)
        local writes = state.native_writes
        input.y = input.y + 3
        s.update()
        local label = route .. ': ' .. case[1]
        if case[2] == 'cancel' then
            assert(state.native_writes == writes and not state.drag_active and state.last_reason == 'native_cancelled',
                label .. ' must cancel the drag before it writes (' .. tostring(state.last_reason) .. ')')
            input.y = input.y + 3
            s.update()
            assert(state.native_writes == writes, label .. ': a cancelled drag wrote')
        else
            assert(state.native_writes == writes + 1 and state.drag_active, label .. ' must not end the drag ('
                .. tostring(state.last_reason) .. ')')
            input.y = input.y + 3
            s.update()
            assert(state.native_writes == writes + 2, label .. ': the re-resolved drag stopped writing')
        end
        assert(state.errors == 0 and not state.native_failed, label .. ': ' .. tostring(state.last_error))
        held_cases = held_cases + 1
    end
end

-- ------------------------------------------- block reads match field reads

-- The shipped memory view reads a model in blocks; a view without read_into
-- reads it one field at a time, the way the offline fixtures do. Over the same
-- memory both must give the same model or the same refusal, for every field of
-- every route set to values that fail each bound in turn.
local FIELDS = {
    grid = {base = 'grid', u = {47540, 597772, 600452, 602052, 600308, 622656, 622660, 602096},
            f = {600424, 0x8C0, 0x8C8, 600416, 284, 288, 372, 412, 420, 428, 904, 1044}},
    career = {base = 'panel', f = {2492, 2496, 2504, 2520, 195268, 195272, 195356, 195396, 195404, 195412,
                                   195824, 195964}},
    bindings = {base = 'list', f = {552, 2784, 2792, 828, 832, 916, 956, 964, 972, 1448, 1588}},
}
FIELDS.loadout, FIELDS.settings = FIELDS.grid, FIELDS.bindings
local MODEL_FIELDS = {'columns', 'rows', 'items', 'kind', 'selected', 'first', 'last', 'anchor', 'content', 'span',
                      'value', 'scroll', 'viewport', 'list_x', 'thumb_ratio', 'rendered_thumb'}

local function describe_model(model, reason)
    if not model then return 'refused: ' .. tostring(reason) end
    local parts = {}
    for _, name in ipairs(MODEL_FIELDS) do
        local value = model[name]
        parts[#parts + 1] = name .. '=' .. (type(value) == 'number' and string.format('%.9g', value) or tostring(value))
    end
    local g = model.geometry
    parts[#parts + 1] = string.format('geometry=%.9g,%.9g,%.9g,%.9g,%.9g', g.left, g.bottom, g.width, g.length, g.thumb)
    return table.concat(parts, ' ')
end

-- What each world holds (new_world and its game update), in model terms.
local GRID_MODEL = {columns = 4, rows = 5, items = 80, kind = 4, selected = 0, first = 28, last = 48, anchor = 7,
                    content = 4018, span = 3000, value = 0.5, scroll = 1500, viewport = 1018,
                    rendered_thumb = 439.5, geometry = {1528, 138, 7 * 4 / 3, 738 * 4 / 3, 134.87964 * 4 / 3}}
local EXPECTED = {
    grid = GRID_MODEL, loadout = GRID_MODEL,
    career = {content = 1315, span = 553, viewport = 762, scroll = 324, value = 324 / 553, list_x = 0,
              kind = 'career', rendered_thumb = 596, geometry = {1528, 128, 10 * 4 / 3, 762 * 4 / 3, 439 * 4 / 3}},
    bindings = {content = 3276, span = 2470, viewport = 806, scroll = 1168, value = 0.473, kind = 'bindings',
                rendered_thumb = 544.444, geometry = {1668.667, 117.333, 8, 806 * 4 / 3, 198.3 * 4 / 3}},
}
EXPECTED.settings = setmetatable({kind = 'settings'}, {__index = EXPECTED.bindings})

local function close_to(a, b)
    if type(a) ~= 'number' or type(b) ~= 'number' then return a == b end
    return math.abs(a - b) <= 1e-3 * math.max(1, math.abs(b))
end

local function reads_world(route, model)
    local expected = EXPECTED[route]
    for _, name in ipairs(MODEL_FIELDS) do
        local want = expected[name]
        if want ~= nil then
            assert(close_to(model[name], want), route .. ' model ' .. name .. ' = ' .. tostring(model[name])
                .. ', the world holds ' .. tostring(want))
        end
    end
    local g = model.geometry
    for index, name in ipairs({'left', 'bottom', 'width', 'length', 'thumb'}) do
        assert(close_to(g[name], expected.geometry[index]), route .. ' geometry ' .. name .. ' = ' .. tostring(g[name]))
    end
end

local compared = 0
for _, route in ipairs({'grid', 'loadout', 'career', 'bindings', 'settings'}) do
    local world = new_world(route)
    world.update()
    local api = module.native_reader()
    api.module = function() return ffi.cast('uint8_t *', image) end
    local block_bridge = assert(module.native_locate(api, module.native_memory(api)))
    assert(block_bridge.memory.read_block, 'the shipped view reads blocks')
    local field_bridge = {}
    for key, value in pairs(block_bridge) do field_bridge[key] = value end
    field_bridge.memory = module.native_memory({read = api.read})
    assert(not field_bridge.memory.read_block)
    reads_world(route, assert(module.native_state(block_bridge)))
    local spare = {}
    local function same(label)
        local by_block = describe_model(module.native_state(block_bridge))
        local refilled = describe_model(module.native_state(block_bridge, spare))
        local by_field = describe_model(module.native_state(field_bridge))
        assert(by_block == by_field, route .. ' ' .. label .. ':\n  blocks ' .. by_block .. '\n  fields ' .. by_field)
        assert(refilled == by_block, route .. ' ' .. label .. ': a refilled model differs')
        compared = compared + 1
    end
    same('as built')
    local spec = FIELDS[route]
    local base = world[spec.base]
    for _, kind in ipairs({'u', 'f'}) do
        local values = kind == 'u' and {0, 1, 9, 17, 100001, 4294967295} or {0, -1, 0.5, 2, 1e6 + 1, -1e7, 0 / 0}
        for _, offset in ipairs(spec[kind] or {}) do
            local cell = ffi.cast(kind == 'u' and u32p or f32p, base + offset)
            local saved = cell[0]
            for _, value in ipairs(values) do
                cell[0] = value -- lint-ok: R3 test only: the test's own fake game memory
                same(string.format('+%d = %s', offset, tostring(value)))
            end
            cell[0] = saved -- lint-ok: R3 test only: the test's own fake game memory
        end
    end
    same('restored')
end

kernel.hd2cs_test_VirtualFree(image_base, 0, 0x8000)
if not PRINT then
    print('frame budget: ' .. checked .. ' frames on 5 routes within their pinned calls (idle, hover, press, held, '
          .. 'verification, release, track press)')
    print('held drags: ' .. held_cases .. ' changes between held frames cancel the drag before it writes, or keep '
          .. 'it when only the reads behind its owner changed')
    print('held garbage: ' .. held_checked .. ' held-frame measurements within budget (still: 0 B; moving: at most '
          .. 'the game routine wrappers\' 16-48 B, interpreted or compiled)')
    print('release garbage: ' .. released .. ' release measurements (5 routes, interpreted and compiled) within '
          .. 'budget: 0 B per release frame, median of ' .. RELEASES .. ' releases of a drag that wrote')
    print('model reads: ' .. compared .. ' models read in blocks equal the same models read field by field, '
          .. 'refilled or new, with every field set to values that fail each bound')
end
