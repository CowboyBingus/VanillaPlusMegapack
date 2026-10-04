-- The Windows functions the runtime calls, declared under private names.
local module = ...

-- --------------------------------------------------------------- platform

-- The Windows functions the platform calls, by library. Each is declared under a
-- private name (__asm__ label): LuaJIT keeps the first prototype declared for a
-- name in the whole process, so a mod that declared GetCursorPos(int32_t *) first
-- broke v2.14. No GDI function and no input synthesis: the screen-capture and
-- wheel routes that needed them are gone from the runtime.
module.platform_functions = {
    user32 = {'GetCursorPos', 'GetAsyncKeyState', 'GetForegroundWindow', 'GetSystemMetrics',
              'GetWindowThreadProcessId', 'GetClientRect', 'ClientToScreen', 'IsWindow'},
    kernel32 = {'GetCurrentProcessId', 'GetTickCount64'},
}

local PLATFORM_DECLARATIONS = [[
    typedef struct { int x; int y; } HD2CS_POINT;
    typedef struct { int left; int top; int right; int bottom; } HD2CS_RECT;
    int hd2cs_GetCursorPos(HD2CS_POINT *point) __asm__("GetCursorPos");
    short hd2cs_GetAsyncKeyState(int key) __asm__("GetAsyncKeyState");
    void *hd2cs_GetForegroundWindow(void) __asm__("GetForegroundWindow");
    int hd2cs_GetSystemMetrics(int index) __asm__("GetSystemMetrics");
    unsigned int hd2cs_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
    unsigned int hd2cs_GetWindowThreadProcessId(void *window, unsigned int *process)
        __asm__("GetWindowThreadProcessId");
    int hd2cs_GetClientRect(void *window, HD2CS_RECT *rect) __asm__("GetClientRect");
    int hd2cs_ClientToScreen(void *window, HD2CS_POINT *point) __asm__("ClientToScreen");
    int hd2cs_IsWindow(void *window) __asm__("IsWindow");
    unsigned long long hd2cs_GetTickCount64(void) __asm__("GetTickCount64");
]]

-- Binds one library's functions by their real names; a missing export is a named
-- startup error.
local function bind_library(ffi, library)
    local loaded, bound = ffi.load(library), {}
    for _, name in ipairs(module.platform_functions[library]) do
        local found, fn = pcall(function() return loaded['hd2cs_' .. name] end)
        if not found then error(library .. '.' .. name .. ' unavailable', 0) end
        bound[name] = fn
    end
    return bound
end

-- libraries, for tests: {user32 = ..., kernel32 = ...} tables holding the
-- functions above; the shipped call binds the real ones.
function module.create_platform(libraries)
    local ffi = require('ffi')
    local bit = require('bit')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Declared once per process, so a second platform (a test) can be created.
    if not pcall(ffi.typeof, 'HD2CS_RECT') then ffi.cdef(PLATFORM_DECLARATIONS) end
    local user32 = libraries and libraries.user32 or bind_library(ffi, 'user32')
    local kernel32 = libraries and libraries.kernel32 or bind_library(ffi, 'kernel32')

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
    -- The virtual desktop's height answers display_height when the foreground
    -- window gives none.
    local SM_CYVIRTUALSCREEN = 79
    local virtual_height = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
    local point = ffi.new('HD2CS_POINT[1]')
    -- Declared later, a shared scratch buffer is a global inside the function and
    -- indexing it raises (the v2.2 "attempt to index global 'rect'" crash).
    local rect, client_origin = ffi.new('HD2CS_RECT[1]'), ffi.new('HD2CS_POINT[1]')
    -- The foreground window's process id, asked every frame: one buffer, no garbage.
    local window_process = ffi.new('unsigned int[1]')

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
        if virtual_height >= 240 then return virtual_height end
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
        -- Cleared first: a failed call leaves the buffer unwritten, which must read
        -- as another process, not as the previous answer.
        window_process[0] = 0
        user32.GetWindowThreadProcessId(window, window_process)
        return window_process[0] == process_id
    end

    -- Nothing to release: the platform holds no device context or bitmap.
    function platform.close() end

    return platform
end
