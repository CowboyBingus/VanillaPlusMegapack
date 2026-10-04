-- Local profiler: times the detector and the frame body, fuzzes hostile settings and
-- degenerate captures, and records reads of names the module does not define.

package.path = (arg and arg[1] or '.') .. '/?.lua;' .. package.path

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local SOURCE = (arg and arg[2]) or 'ClickableScrollbars/src/clickable_scrollbars.lua'
local module = assert(loadfile(SOURCE))()
-- The legacy pixel detector is not shipped in the entry: load it from src/ beside the module.
local function load_detector(target, environment)
    local file = assert(io.open(((arg and arg[1]) or '.') .. '/src/detector.lua', 'rb'))
    local chunk = assert(loadstring(file:read('*a'), '@detector.lua'))
    file:close()
    if environment then setfenv(chunk, environment) end
    chunk(target, {clamp = function(value, low, high)
        if value < low then return low end
        if value > high then return high end
        return value
    end})
end
load_detector(module)

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL ' .. name .. (detail and (' - ' .. tostring(detail)) or ''))
    end
end

-- ------------------------------------------------------------- high-res clock

local now_seconds
do
    local ok, ffi = pcall(require, 'ffi')
    if ok then
        pcall(ffi.cdef, [[
            int QueryPerformanceFrequency(int64_t *value);
            int QueryPerformanceCounter(int64_t *value);
        ]])
        local loaded, kernel32 = pcall(ffi.load, 'kernel32')
        local frequency, counter = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
        if loaded and kernel32.QueryPerformanceFrequency(frequency) ~= 0 then
            local ticks = tonumber(frequency[0])
            now_seconds = function()
                kernel32.QueryPerformanceCounter(counter)
                return tonumber(counter[0]) / ticks
            end
        end
    end
end
if not now_seconds then
    now_seconds = function() return os.clock() end
end

-- Benchmarks the *best* of several runs: the minimum is the least noisy estimate
-- of the work itself, and a regression moves every run up.
local measurements = {}
local function bench(label, iterations, body)
    local rounds = 5
    local best = math.huge
    for _ = 1, 2 do body() end -- warm up, including any JIT compilation
    for _ = 1, rounds do
        local started = now_seconds()
        for _ = 1, iterations do body() end
        local elapsed = (now_seconds() - started) / iterations
        if elapsed < best then best = elapsed end
    end
    local micro = best * 1e6
    measurements[#measurements + 1] = {label = label, micro = micro, iterations = iterations}
    print(string.format('  %-46s %9.1f us/call', label, micro))
    return micro
end

-- ------------------------------------------------------------------- scenes

-- A uniform grey bar on the panel. `bar` may be nil for pure panel.
local function uniform(width, height, bar)
    local function rgb(x, y)
        if bar and x >= bar.left and x <= bar.right and y >= bar.top and y <= bar.bottom then
            return 149, 149, 149
        end
        return 45, 45, 45
    end
    return {width = width, height = height, origin_x = 0, origin_y = 0, rgb = rgb}
end

-- Dense artwork: a chessboard of bright and dark pixels, the shape that makes a
-- naive column probe believe every column holds a thumb.
local function artwork(width, height, bar)
    local function rgb(x, y)
        if bar and x >= bar.left and x <= bar.right and y >= bar.top and y <= bar.bottom then
            return 149, 149, 149
        end
        local value = ((x + y) % 2 == 0) and 200 or 60
        return value, value, value
    end
    return {width = width, height = height, origin_x = 0, origin_y = 0, rgb = rgb}
end

-- Full-height vertical stripes: every bright column passes the brightness and
-- contrast tests for its whole length, so the run scanner has to visit it even
-- though it can never be a thumb (a thumb has panel above and below it).
local function stripes(width, height)
    local function rgb(x, y)
        local light = math.floor(x / 16) % 2 == 0
        local value = light and 200 or 45
        return value, value, value
    end
    return {width = width, height = height, origin_x = 0, origin_y = 0, rgb = rgb}
end

local BAR = {left = 44, right = 55, top = 300, bottom = 620}
local CURSOR = {x = 50, y = 700}
local options = module.parse_settings(nil, nil)

-- ------------------------------------------------------- 1. detector hotspots

print('detector hotspots (per analyse call):')
local wide_uniform = uniform(96, 920, BAR)
local wide_artwork = artwork(96, 920, BAR)
local wide_stripes = stripes(96, 920)
local narrow_uniform = uniform(40, 840, {left = 14, right = 25, top = 260, bottom = 580})

local analyse_wide = bench('analyse 96x920 plain panel + bar', 400, function()
    module.analyse(wide_uniform, CURSOR, options)
end)
local analyse_artwork = bench('analyse 96x920 dense artwork', 200, function()
    module.analyse(wide_artwork, CURSOR, options)
end)
local analyse_stripes = bench('analyse 96x920 full-height stripes', 200, function()
    module.analyse(wide_stripes, CURSOR, options)
end)
local analyse_narrow = bench('analyse 40x840 cached column', 800, function()
    module.analyse(narrow_uniform, {x = 20, y = 700}, options)
end)

local scaled = module.scale_settings(options, module.scale_for_height(2160))
local analyse_4k = bench('analyse 144x1380 at 2160p scale', 200, function()
    module.analyse(uniform(144, 1380, {left = 66, right = 83, top = 450, bottom = 930}),
        {x = 74, y = 1000}, scaled)
end)

print('detector primitives:')
bench('strip_luminance 96x920', 2000, function() module.strip_luminance(wide_uniform) end)
bench('background_luminance 96x920', 2000, function() module.background_luminance(wide_uniform) end)
bench('adapt_options 96x920', 2000, function() module.adapt_options(wide_uniform, options) end)
bench('find_thumb 96x920 plain panel', 400, function() module.find_thumb(wide_uniform, CURSOR, options) end)

-- The column probe has to pay for itself: it must be much cheaper than a full
-- scan on ordinary panels and it must not collapse on dense artwork.
local full = module.parse_settings(nil, nil)
full.probe_step = 1
local probed = module.parse_settings(nil, nil)
probed.probe_step = 8
local function time_analyse(sample, settings, cursor, iterations)
    local best = math.huge
    for _ = 1, 3 do
        local started = now_seconds()
        for _ = 1, iterations do module.analyse(sample, cursor, settings) end
        local elapsed = (now_seconds() - started) / iterations
        if elapsed < best then best = elapsed end
    end
    return best * 1e6
end
local plain_full = time_analyse(wide_uniform, full, CURSOR, 200)
local plain_probed = time_analyse(wide_uniform, probed, CURSOR, 200)
local stripe_full = time_analyse(wide_stripes, full, CURSOR, 100)
local stripe_probed = time_analyse(wide_stripes, probed, CURSOR, 100)
-- The probe's saving is in the scan, so the comparison is made on the scan: the
-- rest of an analysis is the same work either way.
-- Interleaved, so a machine that slows down between the two halves moves both.
local scan_full, scan_probed = math.huge, math.huge
-- Earlier analyse/scale benchmarks compile the same scanner through different
-- callers. LuaJIT's shared trace/blacklist state can leave just one variant in
-- the interpreter (and even enabling the trace logger changes the winner).
-- Start this comparison with fresh traces, then warm both variants equally.
if jit then jit.flush() end
local function time_scan(settings)
    local started = now_seconds()
    for _ = 1, 300 do module.find_thumb(wide_uniform, CURSOR, settings) end
    return (now_seconds() - started) / 300 * 1e6
end
time_scan(full)
time_scan(probed)
for _ = 1, 6 do
    scan_full = math.min(scan_full, time_scan(full))
    scan_probed = math.min(scan_probed, time_scan(probed))
end
print(string.format('  %-46s %9.1f us/call', 'find_thumb, probe off', scan_full))
print(string.format('  %-46s %9.1f us/call', 'find_thumb, probe on', scan_probed))
print(string.format('  %-46s %9.1f us/call', 'full scan, plain panel', plain_full))
print(string.format('  %-46s %9.1f us/call', 'probed scan, plain panel', plain_probed))
print(string.format('  %-46s %9.1f us/call', 'full scan, full-height stripes', stripe_full))
print(string.format('  %-46s %9.1f us/call', 'probed scan, full-height stripes', stripe_probed))

-- Measurement noise on a busy machine moves this ratio by a few points, so the
-- check is set at a level a real regression still cannot reach.
check('the probe is much cheaper on an ordinary panel', scan_probed <= scan_full * 0.85,
    string.format('%.0f us vs %.0f us', scan_probed, scan_full))
check('the probe does not fall back to the full scan on artwork', stripe_probed <= stripe_full * 0.8,
    string.format('%.0f us vs %.0f us', stripe_probed, stripe_full))
check('a wide analyse stays inside a frame on this machine', analyse_wide <= 20000,
    string.format('%.0f us', analyse_wide))
check('dense artwork stays inside a frame on this machine', analyse_artwork <= 40000,
    string.format('%.0f us', analyse_artwork))
check('a 2160p analyse stays inside a frame on this machine', analyse_4k <= 60000,
    string.format('%.0f us', analyse_4k))

-- --------------------------------------------------- 2. runtime frame hotspots

local function fake_platform(options)
    local platform = {wheels = {}, captures = 0}
    platform.state = {
        now = 1000, cursor = {x = 886, y = 700}, down = false, foreground = true,
        bar = {left = 880, right = 891, top = 460, bottom = 700}, shift = 13,
        display_height = options and options.display_height,
    }
    function platform.now() return platform.state.now end
    function platform.cursor() return platform.state.cursor.x, platform.state.cursor.y end
    function platform.pressed() return platform.state.down end
    function platform.key_state() return 0 end
    function platform.foreground_self() return platform.state.foreground end
    function platform.display_height() return platform.state.display_height end
    function platform.close() end
    function platform.wheel(notches)
        platform.wheels[#platform.wheels + 1] = notches
        local bar = platform.state.bar
        local step = platform.state.shift * (notches > 0 and -1 or 1)
        bar.top, bar.bottom = bar.top + step, bar.bottom + step
        return true
    end
    function platform.capture(center_x, center_y, options, strip_width, strip_window)
        platform.captures = platform.captures + 1
        local width = math.min(strip_width or options.strip_width, 240)
        local height = math.min((strip_window or options.window) * 2, 4000)
        local origin_x = center_x - math.floor(width / 2)
        local origin_y = center_y - math.floor(height / 2)
        local bar = platform.state.bar
        local function rgb(x, y)
            local screen_x, screen_y = origin_x + x, origin_y + y
            if screen_x >= bar.left and screen_x <= bar.right
                and screen_y >= bar.top and screen_y <= bar.bottom then
                return 149, 149, 149
            end
            return 45, 45, 45
        end
        return {width = width, height = height, origin_x = origin_x, origin_y = origin_y, rgb = rgb}
    end
    return platform
end

local function boot(platform)
    local environment = {update = function() end, shutdown = function() end,
                         CowboyBingusModLoader = {api = 1, open_log = function() return nil end}}
    local state = module.install(function() return platform end, environment)
    return environment, state
end

local function press(platform, environment, x, y)
    platform.state.down = false
    platform.state.now = platform.state.now + 1
    environment.update(0.016)
    platform.state.cursor = {x = x, y = y}
    platform.state.now = platform.state.now + 1
    platform.state.down = true
    environment.update(0.016)
end

print('runtime hotspots:')
local fixture = assert(loadfile(assert(arg[0]:match('^(.*)[/\\]')) .. '/runtime_fixture.lua'))()
local idle = fixture(module, {visible=false})
bench('idle update frame (no input)', 20000, function() idle.tick(1) end)
check('idle performs no searches or captures', idle.resolves == 1 and idle.captures == 0)
local active = fixture(module)
active.press()
local y = 600
local drag_frames = bench('native drag frame (moving pointer)', 20000, function()
    y = y == 600 and 601 or 600
    active.move(-2000, y)
end)
check('a drag frame costs well under a millisecond', drag_frames <= 200, string.format('%.1f us', drag_frames))
check('a native drag writes without capture or wheel input', active.writes > 0 and active.captures == 0 and active.wheels == 0)
active.release()
check('release ends native ownership', not active.state.drag_active)
local outside = fixture(module, {visible=false})
local press_cost = bench('ordinary click with no visible menu', 5000, function() outside.press(200,600) end)
check('ordinary click remains bounded', press_cost <= 150, string.format('%.1f us',press_cost))
check('ordinary clicks never capture or log', outside.captures == 0 and outside.logs == 0)

-- --------------------------------------------------------- 3. hostile samples

print('edge cases:')
local seed = 20260921
local function rnd(limit)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % limit
end
local function random_scene(width, height)
    local bar = {
        left = rnd(width), top = rnd(height), right = rnd(width), bottom = rnd(height),
    }
    bar.right = math.max(bar.right, bar.left)
    bar.bottom = math.max(bar.bottom, bar.top)
    local tone = rnd(4)
    local function rgb(x, y)
        if x >= bar.left and x <= bar.right and y >= bar.top and y <= bar.bottom then
            return 140 + tone * 10, 140 + tone * 10, 140 + tone * 10
        end
        local value = rnd(220)
        return value, value, value
    end
    return {width = width, height = height, origin_x = 0, origin_y = 0, rgb = rgb}
end

local fuzz_failures = 0
for index = 1, 3000 do
    local width, height = 2 + rnd(140), 2 + rnd(900)
    local sample = random_scene(width, height)
    local cursor = {x = rnd(width + 40) - 20, y = rnd(height + 40) - 20}
    local ok, action, reason = pcall(module.analyse, sample, cursor, options)
    if not ok then
        fuzz_failures = fuzz_failures + 1
        if fuzz_failures <= 3 then print('  fuzz error: ' .. tostring(action)) end
    elseif action then
        local bar = action.bar
        local valid = bar.left >= 0 and bar.right < width and bar.left <= bar.right
            and bar.top >= 0 and bar.bottom < height and bar.top <= bar.bottom
        if not valid then
            fuzz_failures = fuzz_failures + 1
            print(string.format('  fuzz invalid bar: %d,%d,%d,%d in %dx%d', bar.left, bar.top, bar.right,
                bar.bottom, width, height))
        end
    elseif type(reason) ~= 'string' then
        fuzz_failures = fuzz_failures + 1
        print('  fuzz returned no reason')
    end
end
check('3000 random samples are handled without error', fuzz_failures == 0, fuzz_failures)

local hostile = {
    'min_width=60\nmax_width=6\n', 'max_height_ratio=0.1\nmin_height=44\n',
    'min_fill=1\nmax_gap=0\nmax_bridge=0\n', 'min_luma=250\nmax_luma=255\n',
    'min_luma=30\nmax_luma=35\nmin_contrast=200\n', 'window=120\nnarrow_window=120\n',
    'window=1400\nstrip_width=240\nnarrow_width=120\n', 'cursor_mask_radius=320\n',
    'probe_step=64\n', 'settle_checks=1\nmax_corrections=0\ncorrection_notches=1\n',
    'jump_max_notches=1\ndrag_max_notches=1\ndrag_max_step_px=20\n',
    'calibration_min_px=200\ncalibration_max_px=200\n', 'default_pixels_per_notch=0\n',
    'scale_geometry=0\n', 'burst_capture_every=1\nburst_cache_ms=0\n', 'dump_captures=50\n',
}
local hostile_failures = 0
for _, text in ipairs(hostile) do
    local settings = module.parse_settings(text, nil)
    local ok = pcall(module.analyse, wide_uniform, CURSOR, settings)
    if not ok then
        hostile_failures = hostile_failures + 1
        print('  hostile settings error: ' .. text:gsub('\n', ' '))
    end
end
check('hostile settings never raise', hostile_failures == 0, hostile_failures)

-- Degenerate captures: nothing to read, a single column, a blown-out frame,
-- and a cursor the caller forgot to fill in.
local degenerate = {
    {width = 0, height = 0, origin_x = 0, origin_y = 0, rgb = function() return nil end},
    {width = 1, height = 1, origin_x = 0, origin_y = 0, rgb = function() return 255, 255, 255 end},
    {width = 8, height = 16, origin_x = 0, origin_y = 0, rgb = function() return 0, 0, 0 end},
    {width = 96, height = 920, origin_x = 0, origin_y = 0, rgb = function() return nil end},
}
local degenerate_failures = 0
for _, sample in ipairs(degenerate) do
    local cursors = {
        {x = 0, y = 0}, {x = -50, y = -50}, {x = 5000, y = 5000},
        {x = sample.width, y = sample.height},
        {},                      -- a caller that forgot to fill the cursor in
        {x = sample.width / 2, y = sample.height / 2},
    }
    for _, cursor in ipairs(cursors) do
        local ok, action, reason = pcall(module.analyse, sample, cursor, options)
        if not ok or (not action and type(reason) ~= 'string') then
            degenerate_failures = degenerate_failures + 1
            print(string.format('  degenerate %dx%d at %d,%d -> %s', sample.width, sample.height, cursor[1],
                cursor[2], tostring(action or reason)))
        end
    end
end
check('degenerate captures are handled without error', degenerate_failures == 0, degenerate_failures)

-- The runtime must survive a platform that fails in every way at once.
local hostile_platform = fake_platform()
hostile_platform.capture = function() return nil end
hostile_platform.display_height = function() error('no display') end
hostile_platform.cursor = function() return nil end
local hostile_environment, hostile_state = boot(hostile_platform)
hostile_platform.state.down = true
hostile_platform.state.now = hostile_platform.state.now + 1
hostile_environment.update(0.016)
for _ = 1, 50 do
    hostile_platform.state.now = hostile_platform.state.now + 1
    hostile_environment.update(0.016)
end
check('a platform that fails everywhere does not stop the addon',
    hostile_state.status == 'running' and hostile_state.errors == 0,
    hostile_state.status .. ' errors=' .. tostring(hostile_state.errors))
check('the failures are counted instead', (hostile_state.capture_failures or 0) + (hostile_state.geometry_failures or 0)
    >= 1, tostring(hostile_state.capture_failures) .. '/' .. tostring(hostile_state.geometry_failures))

-- ------------------------------------------- 4. unknown-global read audit

-- A name the module does not define is a typo'd global: recorded, never allowed.
local ALLOWED = {
    _G = true, assert = true, error = true, ipairs = true, math = true, next = true, os = true,
    pairs = true, pcall = true, print = true, rawget = true, rawset = true, select = true,
    setfenv = true, string = true, table = true, tonumber = true, tostring = true, type = true,
    unpack = true, io = true, require = true, xpcall = true, coroutine = true, loadstring = true,
    collectgarbage = true, getmetatable = true, setmetatable = true, rawequal = true, ffi = true,
    bit = true, os_getenv = true,
}
local unknown = {}
local sandbox = setmetatable({}, {
    __index = function(_, key)
        if not ALLOWED[key] then unknown[key] = (unknown[key] or 0) + 1 end
        return rawget(_G, key)
    end,
    __newindex = function(table, key, value) rawset(table, key, value) end,
})
sandbox._G = sandbox
sandbox.__CLICKABLE_SCROLLBARS_TEST = true
local chunk = assert(loadstring(assert(io.open(SOURCE, 'rb')):read('*a'), '@' .. SOURCE))
setfenv(chunk, sandbox)
local sandboxed = chunk()
load_detector(sandboxed, sandbox)
assert(type(sandboxed) == 'table' and sandboxed.analyse, 'sandboxed module did not load')

-- Exercise the paths that a press takes, inside the sandbox, with a fake
-- platform, so any unknown global read anywhere in those paths is recorded.
local sandbox_platform = fake_platform()
local sandbox_environment = {update = function() end, shutdown = function() end,
                             CowboyBingusModLoader = {api = 1, open_log = function() return nil end}}
local sandbox_state = sandboxed.install(function() return sandbox_platform end, sandbox_environment)
assert(type(sandbox_state) == 'table', 'sandboxed install failed')
press(sandbox_platform, sandbox_environment, 886, 300)   -- track click, jump and settle
for _ = 1, 60 do
    sandbox_platform.state.now = sandbox_platform.state.now + 17
    sandbox_environment.update(0.016)
end
press(sandbox_platform, sandbox_environment, 886, 600)   -- grab
sandbox_platform.state.cursor = {x = 886, y = 700}
sandbox_platform.state.down = true
sandbox_platform.state.now = sandbox_platform.state.now + 17
sandbox_environment.update(0.016)                        -- drag
for _ = 1, 20 do
    sandbox_platform.state.cursor = {x = 886, y = sandbox_platform.state.cursor.y + 7}
    sandbox_platform.state.now = sandbox_platform.state.now + 17
    sandbox_environment.update(0.016)
end
sandbox_platform.state.down = false
sandbox_platform.state.now = sandbox_platform.state.now + 17
sandbox_environment.update(0.016)
sandboxed.scale_settings(sandboxed.parse_settings('window=700\nprobe_step=2\n', nil), 1.5)
sandboxed.scale_for_height(1080)
sandboxed.decide({top = 1, bottom = 2, left = 1, right = 2}, {x = 1, y = 1}, wide_uniform, options)

local names = {}
for name, count in pairs(unknown) do names[#names + 1] = name .. '=' .. count end
table.sort(names)
check('the module reads no unknown global', #names == 0, table.concat(names, ','))
print('  unknown global reads: ' .. (#names == 0 and 'none' or table.concat(names, ',')))

-- ------------------------------------------------------------------- report

print('slowest measured calls:')
table.sort(measurements, function(a, b) return a.micro > b.micro end)
for index = 1, math.min(5, #measurements) do
    print(string.format('  %-46s %9.1f us/call', measurements[index].label, measurements[index].micro))
end

print(string.format('profile: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
