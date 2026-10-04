-- Windows platform tests: FFI declarations, the platform's Windows functions and
-- GDI objects, and the pixel sampler on a real desktop capture.

package.path = (arg and arg[1] or '.') .. '/?.lua;' .. package.path

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local module = assert(loadfile((arg and arg[2]) or 'ClickableScrollbars/src/clickable_scrollbars.lua'))()
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
local ffi = require('ffi')

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL ' .. name .. (detail and (' - ' .. tostring(detail)) or ''))
    end
end

-- Test-only Windows functions: this process's GDI object count, and the GDI
-- capture the pixel-detector check below uses (the platform has none).
ffi.cdef [[
    typedef struct {
        unsigned int biSize; int biWidth; int biHeight; unsigned short biPlanes;
        unsigned short biBitCount; unsigned int biCompression; unsigned int biSizeImage;
        int biXPelsPerMeter; int biYPelsPerMeter; unsigned int biClrUsed; unsigned int biClrImportant;
    } hd2cs_test_bitmap_info;
    void *hd2cs_test_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    unsigned int hd2cs_test_GetGuiResources(void *process, unsigned int flags) __asm__("GetGuiResources");
    int hd2cs_test_GetSystemMetrics(int index) __asm__("GetSystemMetrics");
    void *hd2cs_test_GetDC(void *window) __asm__("GetDC");
    int hd2cs_test_ReleaseDC(void *window, void *dc) __asm__("ReleaseDC");
    void *hd2cs_test_CreateCompatibleDC(void *dc) __asm__("CreateCompatibleDC");
    void *hd2cs_test_CreateDIBSection(void *dc, hd2cs_test_bitmap_info *info, unsigned int usage,
                                      void **bits, void *section, unsigned int offset) __asm__("CreateDIBSection");
    void *hd2cs_test_SelectObject(void *dc, void *object) __asm__("SelectObject");
    int hd2cs_test_BitBlt(void *dest, int x, int y, int width, int height, void *source,
                          int source_x, int source_y, unsigned int rop) __asm__("BitBlt");
    int hd2cs_test_DeleteObject(void *object) __asm__("DeleteObject");
    int hd2cs_test_DeleteDC(void *dc) __asm__("DeleteDC");
]]
local user32, gdi32, kernel32 = ffi.load('user32'), ffi.load('gdi32'), ffi.load('kernel32')
local function gdi_objects()
    return tonumber(user32.hd2cs_test_GetGuiResources(kernel32.hd2cs_test_GetCurrentProcess(), 0))
end

-- The shipped platform creates no GDI object and holds none for the session:
-- v2.14 kept a screen DC, a memory DC and a 240 x screen-height capture bitmap
-- (1-4 MB) for a capture route the runtime no longer has.
local gdi_before = gdi_objects()
local created, platform = pcall(module.create_platform)
check('create_platform succeeds', created, platform)
if not created then
    print(string.format('platform: %d passed, %d failed', passed, failed))
    os.exit(1)
end
check('creating the platform creates no GDI object', gdi_objects() == gdi_before,
    gdi_before .. ' -> ' .. gdi_objects())
check('the platform has no capture, dump or wheel route', platform.capture == nil and platform.dump == nil
    and platform.wheel == nil)

-- With fakes of exactly the declared Windows functions the platform starts and
-- answers every query: it needs nothing else, and nothing from gdi32.
do
    local calls = {}
    local results = {
        GetCursorPos = function(point) point[0].x, point[0].y = 10, 20; return 1 end,
        GetAsyncKeyState = function() return 0 end,
        GetForegroundWindow = function() return 0x1234 end,
        GetSystemMetrics = function() return 1440 end,
        GetWindowThreadProcessId = function(_, process) process[0] = 7; return 1 end,
        GetClientRect = function(_, rect) rect[0].right, rect[0].bottom = 2560, 1440; return 1 end,
        ClientToScreen = function() return 1 end,
        IsWindow = function() return 1 end,
        GetCurrentProcessId = function() return 7 end,
        GetTickCount64 = function() return 1000 end,
    }
    local libraries, declared = {}, 0
    for library, names in pairs(module.platform_functions) do
        declared = declared + 1
        libraries[library] = {}
        for _, name in ipairs(names) do
            local result = results[name]
            check(name .. ' has a fake', result ~= nil)
            libraries[library][name] = function(...)
                calls[name] = (calls[name] or 0) + 1
                return result(...)
            end
        end
    end
    check('the platform declares only user32 and kernel32 functions', declared == 2
        and libraries.user32 ~= nil and libraries.kernel32 ~= nil)
    local made, fake_platform = pcall(module.create_platform, libraries)
    check('the platform starts on exactly its declared functions', made, fake_platform)
    if made then
        check('the platform answers through them', fake_platform.foreground_self() == true
            and fake_platform.cursor() == 10 and fake_platform.display_height() == 1440
            and fake_platform.viewport().width == 2560 and fake_platform.pressed() == false)
        fake_platform.close()
    end
    for name in pairs(results) do
        check(name .. ' is used', (calls[name] or 0) > 0, name)
    end
end

check('cursor readable', type(platform.cursor()) == 'number' or platform.cursor() == nil)
check('foreground query', type(platform.foreground_self()) == 'boolean')
check('button query', type(platform.pressed()) == 'boolean')
check('key state query', type(platform.key_state()) == 'number')
check('display height readable', platform.display_height() == nil
    or (type(platform.display_height()) == 'number' and platform.display_height() >= 240),
    platform.display_height())

-- The foreground query runs every frame. The game calls it from the interpreted
-- frame step, so it compiles as a trace of its own; compiled, it reuses one buffer
-- and allocates nothing. Without the JIT only the returned window pointer is boxed.
-- Every trace the JIT compiles is a 1-2 KB object in the same heap, and one could
-- land inside a single measured window (it did, once in about 70 runs in the
-- game's lua51.dll). So one loop serves the warm-up and every window, and each
-- round's verdict is the median of WINDOWS windows, which one-off JIT work cannot
-- move, plus their total, which catches a table that grows only now and then. The
-- second round starts with jit.flush() (what a full code cache or another mod
-- does), so its first window always holds the recompilation and the verdict must
-- hold anyway.
do
    local WINDOWS, CALLS = 5, 40000
    local jit_library = rawget(_G, 'jit')
    local compiled = jit_library and jit_library.status and jit_library.status()
    local expected = compiled and 0 or 16 -- bytes per call
    local median_limit = expected * CALLS + 1024 -- about 0.025 bytes per call above it
    local total_limit = expected * CALLS * WINDOWS + 16 * 1024
    local function query(count)
        for _ = 1, count do platform.foreground_self() end
    end
    if jit_library and jit_library.off then jit_library.off(query) end
    local function window()
        collectgarbage('collect'); collectgarbage('stop') -- lint-ok: R4 test only: counts garbage, GC held
        local before = collectgarbage('count')
        query(CALLS)
        local bytes = (collectgarbage('count') - before) * 1024
        collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped above
        return bytes
    end
    local function round(label)
        local sizes, sorted, total = {}, {}, 0
        for index = 1, WINDOWS do
            sizes[index] = window()
            sorted[index], total = sizes[index], total + sizes[index]
        end
        table.sort(sorted)
        local median = sorted[(WINDOWS + 1) / 2]
        local parts = {}
        for index, bytes in ipairs(sizes) do parts[index] = string.format('%.0f', bytes) end
        check('foreground query allocates ' .. (compiled and 'nothing' or 'only the boxed window') .. ' per call ('
            .. label .. ')', median <= median_limit and total <= total_limit,
            string.format('windows of %d calls: %s bytes', CALLS, table.concat(parts, ' ')))
    end
    window() -- warm-up: the query's trace compiles here
    round('warm')
    if jit_library and jit_library.flush then jit_library.flush() end -- lint-ok: R5 test only: recompiles inside the round
    round('after a JIT flush')
end

-- Lint for the v2.2 crash: a scratch buffer declared after its users is a global.
local function blank_non_code(text)
    -- Blank comments and the ffi.cdef string, keeping offsets stable so
    -- positions still compare. Parameter names inside the cdef block are not
    -- code and must not count as uses.
    text = text:gsub('%-%-[^\n]*', function(comment) return string.rep(' ', #comment) end)
    return (text:gsub('ffi%.cdef%s*%[%[.-%]%]', function(block) return string.rep(' ', #block) end))
end

local source_path = (arg and arg[2]) or 'ClickableScrollbars/src/clickable_scrollbars.lua'
local handle = assert(io.open(source_path, 'rb'))
local raw_text = handle:read('*a')
handle:close()
-- Locate the section on the raw text (the closing marker is itself a comment),
-- then lint the comment-free copy so a mention inside a comment cannot count.
local first = raw_text:find('function module%.create_platform')
local last = raw_text:find('%-%- %-+ install')
local source_text = blank_non_code(raw_text)
check('platform section located for the buffer lint', first ~= nil and last ~= nil)
if first and last then
    local section = source_text:sub(first, last)
    local buffers, offenders = 0, 0
    -- Every local initialised from ffi.new counts, including the multi-name form
    -- `local rect, client_origin = ffi.new(...), ffi.new(...)` that carried the
    -- shipped bug.
    for position, line in section:gmatch('()([^\n]*ffi%.new[^\n]*)') do
        local names = line:match('^%s*local%s+([%a_][%w_,%s]*)%s*=')
        if names then
            for name in names:gmatch('[%a_][%w_]*') do
                buffers = buffers + 1
                local pattern = '%f[%a_]' .. name .. '%f[^%a%d_]'
                local search, first_use = 1, nil
                while true do
                    local found = section:find(pattern, search)
                    if not found then break end
                    if found < position then first_use = first_use or found end
                    search = found + 1
                end
                if first_use then
                    offenders = offenders + 1
                    check(name .. ' buffer is declared before every use', false,
                        'first use at offset ' .. first_use .. ', declared at ' .. position)
                end
            end
        end
    end
    check('platform buffers were linted', buffers >= 4, buffers)
    check('no buffer is used before its declaration', offenders == 0, offenders)
end

-- A strip of the real desktop for the pixel detector, copied out so that its GDI
-- objects are released at once. The detector's own tests use synthetic strips.
local function desktop_capture(center_x, center_y, options)
    local left, top = user32.hd2cs_test_GetSystemMetrics(76), user32.hd2cs_test_GetSystemMetrics(77)
    local screen_width = user32.hd2cs_test_GetSystemMetrics(78)
    local screen_height = user32.hd2cs_test_GetSystemMetrics(79)
    local width = math.min(options.strip_width, screen_width)
    local height = math.min(options.window * 2, screen_height)
    if width < 8 or height < 16 then return nil end
    local origin_x = math.max(left, math.min(math.floor(center_x - width / 2), left + screen_width - width))
    local origin_y = math.max(top, math.min(math.floor(center_y - height / 2), top + screen_height - height))
    local screen = user32.hd2cs_test_GetDC(nil)
    local memory = gdi32.hd2cs_test_CreateCompatibleDC(screen)
    local info = ffi.new('hd2cs_test_bitmap_info')
    info.biSize, info.biWidth, info.biHeight = ffi.sizeof(info), width, -height -- top-down rows
    info.biPlanes, info.biBitCount = 1, 32
    local bits = ffi.new('void *[1]')
    local bitmap = gdi32.hd2cs_test_CreateDIBSection(screen, info, 0, bits, nil, 0)
    local copy, stride = nil, width * 4
    if bitmap ~= nil and bits[0] ~= nil then
        local previous = gdi32.hd2cs_test_SelectObject(memory, bitmap)
        if gdi32.hd2cs_test_BitBlt(memory, 0, 0, width, height, screen, origin_x, origin_y,
                                   0x00CC0020 + 0x40000000) ~= 0 then -- SRCCOPY | CAPTUREBLT
            copy = ffi.new('uint8_t[?]', stride * height)
            ffi.copy(copy, bits[0], stride * height)
        end
        gdi32.hd2cs_test_SelectObject(memory, previous)
        gdi32.hd2cs_test_DeleteObject(bitmap)
    end
    gdi32.hd2cs_test_DeleteDC(memory)
    user32.hd2cs_test_ReleaseDC(nil, screen)
    if not copy then return nil end
    local sample = {width = width, height = height, stride = stride, origin_x = origin_x, origin_y = origin_y}
    function sample.rgb(x, y)
        if x < 0 or y < 0 or x >= width or y >= height then return nil end
        local offset = y * stride + x * 4
        return copy[offset + 2], copy[offset + 1], copy[offset]
    end
    return sample
end

local options = module.parse_settings(nil, nil)
local skip_capture = arg and arg[3] == '--skip-capture'
local sample
if skip_capture then
    print('SKIP desktop capture: interactive Windows desktop unavailable; not verified')
else
    local before = gdi_objects()
    sample = desktop_capture(400, 400, options)
    check('capture returns a sample', sample ~= nil)
    check('the test capture releases its GDI objects', gdi_objects() == before, before .. ' -> ' .. gdi_objects())
end
if sample then
    check('capture width matches', sample.width == math.min(options.strip_width, sample.width),
        sample.width)
    check('capture height is bounded', sample.height > 0 and sample.height <= options.window * 2 + 2,
        sample.height)
    check('capture stride is a row multiple', sample.stride % 4 == 0 and sample.stride >= sample.width * 4,
        sample.stride)
    local luminance = module.strip_luminance(sample)
    check('strip luminance readable', luminance ~= nil and luminance >= 0 and luminance <= 255, luminance)
    local action, reason = module.analyse(sample, {x = 0, y = 0}, options)
    check('analysis returns a decision', action ~= nil or type(reason) == 'string', reason)
end

platform.close()
check('close is idempotent', pcall(platform.close))
check('no GDI object is left behind', gdi_objects() == gdi_before, gdi_before .. ' -> ' .. gdi_objects())

-- Nothing at runtime can need GDI: the addon names no GDI function, and nothing
-- calls a capture or dump route (the runtime fixtures also raise if one is called).
check('the addon names no GDI function', not raw_text:find('gdi32', 1, true)
    and not raw_text:find('CreateDIBSection', 1, true) and not raw_text:find('BitBlt', 1, true)
    and not raw_text:find('CreateCompatibleDC', 1, true) and not raw_text:find('SelectObject', 1, true))
check('the addon declares no input synthesis', not raw_text:find('SendInput', 1, true)
    and not raw_text:find('MOUSEINPUT', 1, true) and not raw_text:find('mouse_event', 1, true)
    and not raw_text:find('keybd_event', 1, true))
check('nothing defines or calls a wheel route', not source_text:find('%.wheel%s*%('))
check('nothing calls a capture or dump route', not source_text:find('%.capture%s*%(')
    and not source_text:find('%.dump%s*%('))

print(string.format('platform: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
