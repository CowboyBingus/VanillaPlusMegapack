-- Offline tests for Sticky Grenade Handles: the real Bingus Shared Runtime (reads, page checks and writes on
-- this test process) against synthetic engine structures in FFI memory, with exact per-scenario call budgets.
-- Usage: luajit tests/test_mod.lua <project root>   (also run in the game's lua51.dll by scripts/build.py)
local root = assert(arg[1], 'project root required')
local H = dofile(root .. '/tests/hostile_vm.lua')
-- A mod that loaded first declared the plain Windows names with a wrong prototype; the runtime's private
-- names must keep working.
local clash = H.clash({'GetModuleHandleA', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
                       'WriteProcessMemory'})
local ffi = require('ffi')
local budget = dofile(root .. '/tests/frame_budget.lua')
local runtime = dofile(root .. '/src/bingus_runtime.lua')
local memory = dofile(root .. '/src/bingus_memory.lua')
local writes = dofile(root .. '/src/bingus_write.lua')
local Mod = dofile(root .. '/src/sticky_grenade_handles.lua')
local PRINT_BUDGETS = os.getenv('SGH_PRINT_BUDGETS') ~= nil
local passed = 0

local function le32(v)
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function le64(v) return le32(v % 4294967296) .. le32(math.floor(v / 4294967296)) end

local function pin(frame, limits, label)
    if PRINT_BUDGETS then print(label .. ': ' .. budget.describe(frame)) end
    budget.check(frame, limits, label)
    for name, limit in pairs(limits) do
        assert((frame[name] or 0) == limit, label .. ': api.' .. name .. ' ' .. tostring(frame[name])
            .. ' calls, pinned ' .. limit)
    end
end

local function expect_error(pattern, fn, ...)
    local ok, err = pcall(fn, ...)
    assert(not ok, 'expected an error matching ' .. pattern)
    assert(tostring(err):find(pattern, 1, true), 'error "' .. tostring(err) .. '" lacks "' .. pattern .. '"')
end

-- Synthetic engine ---------------------------------------------------------------------------------------

local LAYOUT = {library_rva = 0x100, library_vtable_rva = 0x200, settings_rva = 0x100, throwable_table = 0x40,
                throwable_slots = 92, throwable_records = 1472, throwable_size = 360}
local THERMITE, STUN = Mod.GRENADES[1], Mod.GRENADES[2]
local OTHER = {lo = 0x11111111, hi = 0x22222222} -- an unrelated throwable in the table

local keep = {}
local function block(size)
    local bytes = ffi.new('uint8_t[?]', size)
    keep[#keep + 1] = bytes
    return ffi.cast('uint8_t *', bytes)
end
local function address(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end
local function put(pointer, offset, bytes) ffi.copy(pointer + offset, bytes, #bytes) end
local function get32(pointer, offset)
    local s = ffi.string(pointer + offset, 4)
    local a, b, c, d = s:byte(1, 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function cstring(text)
    local p = block(#text + 1)
    put(p, 0, text .. '\0')
    return p
end

-- A material library with the given entries {name, tag, owned} (owned: the hkStringPtr ownership bit), and the
-- throwable settings with the given records {grenade, sticky, material}. options change one thing at a time.
local function World(options)
    options = options or {}
    local w = {exe = block(0x400), game = block(0x400)}
    local materials = options.materials or {
        {name = 'default', tag = 0},
        {name = 'throwable', tag = Mod.THROWABLE, owned = true},
        {name = 'water_gameplay', tag = 0x125DBB65},
        {name = 'sticky_grenade_handle', tag = Mod.HANDLE, owned = true},
        {name = nil, tag = 0}, -- a free slot
    }
    local count = #materials
    w.entries = block(count * 80)
    for i, material in ipairs(materials) do
        local offset = (i - 1) * 80
        if material.name then
            put(w.entries, offset, le64(address(cstring(material.name)) + (material.owned and 1 or 0)))
        end
        put(w.entries, offset + 0x48, le64(material.tag))
        if material.name == 'sticky_grenade_handle' then w.handle = w.entries + offset + 0x48 end
    end
    w.library = block(0x60)
    put(w.library, 0, le64(address(w.exe) + (options.vtable or LAYOUT.library_vtable_rva)))
    put(w.library, 0x48, le64(address(w.entries)))
    put(w.library, 0x50, le32(options.count or count) .. le32(options.capacity or count + 0x80000000))
    if not options.no_library then put(w.exe, LAYOUT.library_rva, le64(address(w.library))) end
    local records = options.records or {
        {grenade = OTHER, sticky = 0, material = Mod.THROWABLE},
        {grenade = THERMITE, sticky = 1, material = Mod.THROWABLE},
        {grenade = STUN, sticky = 1, material = Mod.THROWABLE},
    }
    local size = LAYOUT.throwable_records + #records * LAYOUT.throwable_size
    local settings = block(24 + size)
    put(settings, 0, 'LDLD' .. le32(options.block_version or 1) .. le32(0x5961C6FB) .. le32(size)
        .. le32(1) .. le32(0))
    w.table = settings + 24
    local used = {}
    for i, record in ipairs(records) do
        local slot = (record.grenade.lo + i * 7) % LAYOUT.throwable_slots
        while used[slot] do slot = (slot + 1) % LAYOUT.throwable_slots end -- open addressing, like the game
        used[slot] = true
        put(w.table, slot * 16, le32(record.grenade.lo) .. le32(record.grenade.hi) .. le32(i - 1) .. le32(0))
        local at = LAYOUT.throwable_records + (i - 1) * LAYOUT.throwable_size
        put(w.table, at + 0x54, string.char(record.sticky))
        put(w.table, at + 0x164, le32(record.material))
    end
    w.root = block(0x60)
    if not options.no_settings then put(w.root, LAYOUT.throwable_table, le64(address(w.table))) end
    if not options.no_root then put(w.game, LAYOUT.settings_rva, le64(address(w.root))) end
    return w
end

-- The runtime api over the synthetic modules; verify_build answers like the real one for a matching build.
local function Api(w, build_ok)
    local api = writes.extend(memory.new(runtime))
    function api.module(name)
        if name == nil then return w.exe end
        if name == 'game.dll' then return w.game end
    end
    function api.verify_build()
        if build_ok == false then return false, 'unsupported game build' end
        return true
    end
    return api
end

local function Loader()
    local loader = {api = 1, lines = {}}
    function loader.open_log()
        return {write = function(_, text) loader.lines[#loader.lines + 1] = text end, flush = function() end}
    end
    function loader.text() return table.concat(loader.lines) end
    return loader
end

local function tag_of(w) return get32(w.handle, 0) end

local function test(name, fn)
    fn()
    passed = passed + 1
    if PRINT_BUDGETS then print('ok ' .. name) end
end

-- Mod.attempt ----------------------------------------------------------------------------------------------

test('applied: one write of the throwable tag into the handle material', function()
    local w = World()
    local api = Api(w)
    local counts = budget.wrap(api)
    local frame, result, tag, index = budget.frame(counts, Mod.attempt, api, w.exe, w.game, LAYOUT)
    assert(result == 'applied' and index == 3, tostring(result) .. ' ' .. tostring(index))
    assert(address(tag) == address(w.handle))
    assert(tag_of(w) == Mod.THROWABLE, 'tag not written')
    assert(get32(w.handle, 4) == 0, 'high dword of userData changed')
    pin(frame, {read = 13, pointer = 8, distance = 1, write = 1, writable_data = 1}, 'attempt applied')
    -- Every other entry is untouched.
    assert(get32(w.entries, 80 + 0x48) == Mod.THROWABLE and get32(w.entries, 160 + 0x48) == 0x125DBB65)
end)

test('already applied: the name decides, nothing is written', function()
    local w = World()
    local api = Api(w)
    assert(Mod.attempt(api, w.exe, w.game, LAYOUT) == 'applied')
    local counts = budget.wrap(api)
    local frame, result, _, index = budget.frame(counts, Mod.attempt, api, w.exe, w.game, LAYOUT)
    assert(result == 'already applied' and index == 3)
    pin(frame, {read = 12, pointer = 8, distance = 1}, 'attempt already applied')
end)

test('waits: no settings (checked first), no library, no materials', function()
    local function waits(options, pattern, limits, label)
        local w = World(options)
        local api = Api(w)
        local counts = budget.wrap(api)
        local frame, result, detail = budget.frame(counts, Mod.attempt, api, w.exe, w.game, LAYOUT)
        assert(result == 'wait' and detail:find(pattern, 1, true), tostring(result) .. ' ' .. tostring(detail))
        if limits then pin(frame, limits, label) end
        if w.handle then assert(tag_of(w) == Mod.HANDLE, 'wrote while waiting: ' .. pattern) end
    end
    -- The settings root, then its table: the cheap checks of the frames spent waiting at the splash screen.
    waits({no_root = true, no_library = true}, 'settings', {read = 1, pointer = 1}, 'attempt without settings root')
    waits({no_settings = true}, 'settings', {read = 2, pointer = 2}, 'attempt without settings table')
    waits({no_library = true}, 'material library', {read = 5, pointer = 3}, 'attempt without library')
    waits({materials = {{name = 'default', tag = 0}, {name = nil, tag = 0}}}, 'materials')
end)

test('refuses: anything that differs from the build', function()
    local function refuses(pattern, options)
        local w = World(options)
        expect_error(pattern, Mod.attempt, Api(w), w.exe, w.game, LAYOUT)
        if w.handle then assert(tag_of(w) == Mod.HANDLE, 'wrote although refused: ' .. pattern) end
    end
    refuses('Unexpected material library', {vtable = 0x208})
    refuses('Unexpected material count', {count = 0})
    refuses('Unexpected material count', {count = 2000, capacity = 2000})
    refuses('Unexpected material count', {count = 5, capacity = 4})
    refuses('No sticky_grenade_handle material', {materials = {
        {name = 'throwable', tag = Mod.THROWABLE}, {name = 'sticky_grenade_shaft', tag = Mod.HANDLE}}})
    refuses('No throwable material', {materials = {
        {name = 'sticky_grenade_handle', tag = Mod.HANDLE}, {name = 'thrown', tag = Mod.THROWABLE}}})
    refuses('Two sticky_grenade_handle materials', {materials = {{name = 'throwable', tag = Mod.THROWABLE},
        {name = 'sticky_grenade_handle', tag = Mod.HANDLE}, {name = 'sticky_grenade_handle', tag = Mod.HANDLE}}})
    refuses('Two throwable materials', {materials = {{name = 'throwable', tag = Mod.THROWABLE},
        {name = 'sticky_grenade_handle', tag = Mod.HANDLE}, {name = 'throwable', tag = Mod.THROWABLE}}})
    refuses('Unexpected throwable settings block', {block_version = 2})
    refuses('No throwable settings for the sticky stun grenade', {records = {
        {grenade = THERMITE, sticky = 1, material = Mod.THROWABLE}}})
    refuses('The G-123 Thermite no longer sticks', {records = {
        {grenade = THERMITE, sticky = 0, material = Mod.THROWABLE},
        {grenade = STUN, sticky = 1, material = Mod.THROWABLE}}})
    refuses('The sticky stun grenade no longer sticks', {records = {
        {grenade = THERMITE, sticky = 1, material = Mod.THROWABLE},
        {grenade = STUN, sticky = 1, material = Mod.HANDLE}}})
end)

test('refuses: the write is refused or does not hold', function()
    local w = World()
    local api = Api(w)
    api.writable_data = function() return false end
    expect_error('Material write refused or failed', Mod.attempt, api, w.exe, w.game, LAYOUT)
    assert(tag_of(w) == Mod.HANDLE)
    api = Api(w)
    api.write = function() return true end -- claims success, writes nothing
    expect_error('Material write did not hold', Mod.attempt, api, w.exe, w.game, LAYOUT)
end)

-- Mod.install ----------------------------------------------------------------------------------------------

local function previous_update(env)
    env.frames = 0
    env.update = function(dt, extra)
        env.frames = env.frames + 1
        return 'vanilla', dt, extra
    end
    return env.update
end

test('install: applied at load, no update hook, shutdown check', function()
    local w, loader, env = World(), Loader(), {}
    local vanilla = previous_update(env)
    local shut = 0
    env.shutdown = function(...) shut = shut + 1; return 'bye', ... end
    local api = Api(w)
    local counts = budget.wrap(api)
    local frame, state = budget.frame(counts, Mod.install, api, {env = env, layout = LAYOUT, loader = loader})
    pin(frame, {read = 13, pointer = 8, distance = 1, write = 1, writable_data = 1, module = 2,
                verify_build = 1}, 'install applied at load')
    assert(state.applied and env.StickyGrenadeHandles == state and state.index == 3)
    assert(env.update == vanilla, 'an update hook was installed although the change was applied at load')
    assert(loader.text():find('applied (material 3', 1, true) and loader.text():find('at load', 1, true))
    assert(tag_of(w) == Mod.THROWABLE)
    frame = budget.frame(counts, env.update, 1 / 60)
    pin(frame, {}, 'frame after load')
    local results
    frame, results = budget.frame(counts, function(...) return {env.shutdown(...)} end, 'quit')
    pin(frame, {read = 1}, 'shutdown')
    assert(shut == 1 and results[1] == 'bye' and results[2] == 'quit')
    assert(loader.text():find('At shutdown: the handle material still sticks.', 1, true))
end)

test('install: shutdown reports a lost tag', function()
    local w, loader, env = World(), Loader(), {}
    Mod.install(Api(w), {env = env, layout = LAYOUT, loader = loader})
    put(w.handle, 0, le32(Mod.HANDLE))
    env.shutdown()
    assert(loader.text():find('lost the throwable tag', 1, true))
end)

test('install: refused build or loader writes nothing and hooks nothing', function()
    local w, loader, env = World(), Loader(), {}
    local vanilla = previous_update(env)
    local api = Api(w, false)
    local counts = budget.wrap(api)
    local frame, state = budget.frame(counts, Mod.install, api, {env = env, layout = LAYOUT, loader = loader})
    pin(frame, {verify_build = 1}, 'install refused build')
    assert(not state.applied and state.status:find('Unsupported game build', 1, true))
    assert(env.update == vanilla and env.shutdown == nil and tag_of(w) == Mod.HANDLE)
    assert(loader.text():find('disabled: Unsupported game build (needs Steam build 25480438)', 1, true))

    env = {}
    state = Mod.install(Api(w), {env = env, layout = LAYOUT, loader = {api = 2}})
    assert(state.status:find('API 1 required', 1, true) and tag_of(w) == Mod.HANDLE)
end)

test('install: refused data at load hooks nothing', function()
    local w, loader, env = World({vtable = 0x208}), Loader(), {}
    local vanilla = previous_update(env)
    local state = Mod.install(Api(w), {env = env, layout = LAYOUT, loader = loader})
    assert(state.status:find('^disabled: ') and state.status:find('Unexpected material library', 1, true))
    assert(env.update == vanilla and env.shutdown == nil)
end)

test('fallback: waits with two reads per frame, applies, then unhooks', function()
    local w, loader, env = World({no_settings = true}), Loader(), {}
    local vanilla = previous_update(env)
    local api = Api(w)
    local counts = budget.wrap(api)
    local frame, state = budget.frame(counts, Mod.install, api, {env = env, layout = LAYOUT, loader = loader})
    pin(frame, {read = 2, pointer = 2, module = 2, verify_build = 1}, 'install waiting')
    assert(env.update ~= vanilla and state.status:find('waiting', 1, true))
    assert(loader.text():find('Waiting for the game: the throwable settings are not loaded yet.', 1, true))
    for n = 1, 3 do
        local results
        frame, results = budget.frame(counts, function() return {env.update(0.5, 'x')} end)
        pin(frame, {read = 2, pointer = 2}, 'waiting frame')
        assert(results[1] == 'vanilla' and results[2] == 0.5 and results[3] == 'x' and env.frames == n)
    end
    env.update(1 / 60) -- warm-up, then no C types per waiting frame
    assert(H.ctype_growth(env.update, 1 / 60) == 0, 'C types created per waiting frame')
    put(w.root, LAYOUT.throwable_table, le64(address(w.table)))
    frame = budget.frame(counts, env.update, 0.5)
    pin(frame, {read = 13, pointer = 8, distance = 1, write = 1, writable_data = 1}, 'frame that applies')
    assert(state.applied and tag_of(w) == Mod.THROWABLE and env.update == vanilla, 'did not unhook')
    -- Waited: 3 frames of 0.5 s, the warm-up and the C type probe (1/60 s each); the applying frame adds none.
    assert(loader.text():find('applied (material 3', 1, true) and loader.text():find('after 1.5 s', 1, true))
    frame = budget.frame(counts, env.update, 1 / 60)
    pin(frame, {}, 'frame after fallback')
end)

test('fallback: gives up after WAIT_SECONDS and unhooks', function()
    local w, loader, env = World({no_settings = true}), Loader(), {}
    local vanilla = previous_update(env)
    local state = Mod.install(Api(w), {env = env, layout = LAYOUT, loader = loader})
    for _ = 1, 10 do env.update(Mod.WAIT_SECONDS / 4) end
    assert(env.update == vanilla and state.status:find('disabled: ', 1, true) and state.status:find('gave up'))
    assert(loader.text():find('settings are not loaded yet', 1, true) and tag_of(w) == Mod.HANDLE)
end)

test('fallback: no previous update, a hostile neighbour below and above', function()
    -- Nothing below: the hook ends with an empty update.
    local w, env = World({no_library = true}), {}
    Mod.install(Api(w), {env = env, layout = LAYOUT, loader = Loader()})
    env.update(0.1)
    put(w.exe, LAYOUT.library_rva, le64(address(w.library)))
    env.update(0.1)
    assert(type(env.update) == 'function' and env.update(0.1) == nil and tag_of(w) == Mod.THROWABLE)

    -- A failing update below: its error object reaches the game unchanged, the hook keeps working.
    w, env = World({no_library = true}), {}
    previous_update(env)
    local below = H.chain(env, 'throw_below', {raise_on = 2})
    Mod.install(Api(w), {env = env, layout = LAYOUT, loader = Loader()})
    assert(pcall(env.update, 0.1))
    local ok, err = pcall(env.update, 0.1)
    assert(not ok and type(err) == 'table' and err.hostile_vm == 'throw_below', 'error below was changed')
    put(w.exe, LAYOUT.library_rva, le64(address(w.library)))
    assert(pcall(env.update, 0.1) and tag_of(w) == Mod.THROWABLE)
    assert(below ~= nil)

    -- A mod that wraps update later: the hook stays as a pass-through with no api calls.
    w, env = World({no_library = true}), {}
    previous_update(env)
    local api = Api(w)
    local counts = budget.wrap(api)
    Mod.install(api, {env = env, layout = LAYOUT, loader = Loader()})
    H.chain(env, 'rehook')
    env.update(0.1)
    put(w.exe, LAYOUT.library_rva, le64(address(w.library)))
    env.update(0.1)
    assert(tag_of(w) == Mod.THROWABLE)
    local frame = budget.frame(counts, env.update, 0.1)
    pin(frame, {}, 'pass-through frame under a later mod')
end)

for name, status in pairs(clash) do
    assert(status == 'clashed' or status == 'already declared', name .. ': ' .. status)
end
print(string.format('PASS: %d Sticky Grenade Handles tests (%s)', passed, jit and jit.version or _VERSION))
