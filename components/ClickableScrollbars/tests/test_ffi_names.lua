-- FFI name clashes: another mod has already declared the Windows functions this
-- addon calls, under their real names and with other prototypes. LuaJIT keeps the
-- first prototype declared for a name in the whole process (a later ffi.cdef of
-- the same name raises nothing), so the addon must not depend on its own
-- declarations of those names. A third-party mod broke v2.14 exactly this way.

package.path = (arg and arg[1] or '.') .. '/?.lua;' .. package.path

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)

local ffi = require('ffi')
ffi.cdef [[
    int GetCursorPos(int32_t *point);
    int GetClientRect(void *window, int32_t *rect);
    int ClientToScreen(void *window, int32_t *point);
    void *CreateDIBSection(void *dc, int32_t *info, unsigned int usage, void **bits, void *section, unsigned int offset);
    bool IsWindow(void *window);
    uintptr_t GetModuleHandleA(const char *name);
    bool ReadProcessMemory(void *process, uintptr_t address, void *buffer, size_t size, size_t *read);
]]

local module = assert(loadfile((arg and arg[2]) or 'ClickableScrollbars/src/clickable_scrollbars.lua'))()

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL ' .. name .. (detail and (' - ' .. tostring(detail)) or ''))
    end
end

local created, platform = pcall(module.create_platform)
check('create_platform succeeds despite clashing declarations', created, platform)
if created then
    local x, y = platform.cursor()
    check('cursor readable', type(x) == 'number' and type(y) == 'number', x)
    check('button query', type(platform.pressed()) == 'boolean')
    local height = platform.display_height()
    check('display height readable', height == nil or (type(height) == 'number' and height >= 240), height)
    platform.close()
end

local built, api = pcall(module.native_reader)
check('memory reader builds despite clashing declarations', built and type(api) == 'table', api)
if built and type(api) == 'table' then
    local buffer = ffi.new('uint8_t[4]', 1, 2, 3, 4)
    check('reader reads this process', api.read(ffi.cast('uint8_t *', buffer), 4) == '\1\2\3\4')
    check('reader finds a loaded module', api.module('kernel32.dll') ~= nil)
    check('reader refuses a module that is not loaded', api.module('hd2cs-not-loaded.dll') == nil)
    local source, into = ffi.cast('uint8_t *', buffer), ffi.new('uint8_t[4]')
    check('reader fills a caller buffer', api.read_into(source, into, 4) == true and into[0] == 1 and into[3] == 4)
    local unreadable = ffi.cast('uint8_t *', 16)
    check('reader refuses an unreadable address', api.read_into(unreadable, into, 4) == false
        and api.read(unreadable, 4) == nil)
    check('reader refuses a bad size', api.read_into(source, into, 0) == false and api.read(source, 40000) == nil)
    -- Reads allocate nothing: a buffer read fills the caller's buffer, and a string
    -- read of unchanged bytes returns the interned string. Interpreted, so that
    -- compiled-trace allocation sinking cannot hide garbage; two window sizes,
    -- so that the measurement's own constant cost cancels.
    local function reads(count)
        for _ = 1, count do api.read_into(source, into, 4); api.read(source, 4) end
    end
    local function garbage(count)
        collectgarbage('collect'); collectgarbage('stop') -- lint-ok: R4 test only: counts garbage, GC held
        local before = collectgarbage('count')
        reads(count)
        local bytes = (collectgarbage('count') - before) * 1024
        collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped above
        return bytes
    end
    local jit_library = rawget(_G, 'jit')
    if jit_library then jit_library.off() end -- lint-ok: R5 test only: measures the interpreter
    reads(100)
    local per_read = (garbage(2000) - garbage(1000)) / 2000
    if jit_library then jit_library.on() end -- lint-ok: R5 test only: restores the JIT
    -- v2.14 allocated about 52 bytes per read here; the windows differ by a few
    -- bytes of the collector's own bookkeeping.
    check('reads allocate nothing', per_read < 0.25, string.format('%.2f bytes per read', per_read))
end

local ran, native, reason = pcall(module.native_api)
check('native_api fails closed outside the game', ran and native == nil and type(reason) == 'string',
    tostring(native) .. ' ' .. tostring(reason))

print(string.format('ffi names: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
