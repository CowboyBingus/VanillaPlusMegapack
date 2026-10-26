-- Know Your Constellation's Lua part (src/components/know_your_constellation/lua/forecast_panel.lua) on LuaJIT's real
-- ffi, against build/tests/kyc_lua_probe.dll (tests/lua/kyc_lua_probe.c: the pack's kyc_lua.c and kyc_gui.c with a
-- scripted panel) and a fake engine that records every call. What only the game can show (the real stingray calls'
-- behaviour, the war table's worlds, the drawn panel) is out of reach here.
-- Usage: luajit tests/lua/know_your_constellation_test.lua <repository> <kyc_lua_probe.dll>
local root, probe_path = arg[1], arg[2]
assert(root and probe_path, 'usage: know_your_constellation_test.lua <repository> <kyc_lua_probe.dll>')
local ffi = require('ffi')
local SOURCE = root .. '/src/components/know_your_constellation/lua/forecast_panel.lua'

local checks, failures = 0, 0
local function check(condition, what)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        print('  FAILED ' .. what)
    end
end
local function run(name, fn)
    print('run  ' .. name)
    local before = failures
    fn()
    print((failures == before and 'ok   ' or 'FAIL ') .. name)
end

ffi.cdef [[
    double *probe_results(void);
    int32_t *probe_counts(void);
    int probe_work(void);
    int probe_route(void);
    const char *probe_absent(void);
    const char *probe_error(void);
    void probe_scroll(int on);
    int probe_tick(int what);
]]
local probe = ffi.load(probe_path)
local r, counts = probe.probe_results(), probe.probe_counts()
local ADOPT, SHOW, SHOW_OTHER, CLEAR, SUSPEND, SHOW_MOVED = 0, 1, 2, 3, 4, 5

-- ---- the fake engine ----------------------------------------------------------------------------------------------
local fake, calls = {}, {}
local function log(...) calls[#calls + 1] = {...} end
local function reset_calls() calls = {} end
-- Worlds are new objects on every call, equal by name (__eq): the Lua part must compare them, not use them as keys.
local world_mt = {__eq = function(a, b) return a.name == b.name end}
local function world(name) return setmetatable({name = name}, world_mt) end
local made = 0
local Vector2 = setmetatable({x = function(v) return v.x end}, {__call = function(_, x, y) return {x = x, y = y} end})
local engine = {
    Application = {
        main_world = function() log('main_world') return world('main') end,
        worlds = function()
            log('worlds')
            if fake.no_list then return nil end
            return {world('main'), world('ui'), world('other')}
        end,
    },
    World = {
        create_screen_gui = function(w, mode, a, b)
            log('create', w.name, mode, a, b)
            made = made + 1
            return {gui = made}
        end,
        destroy_gui = function(w, g) log('destroy', w.name, g.gui) end,
    },
    Gui = {
        material = function(g, id) log('material', g.gui, id.hex) return {material = true} end,
        resolution = function() log('resolution') return 2560, 1440 end,
        text_extents = function(g, text, font, size)
            log('extents', text, font.hex, size)
            return Vector2(-1, 0), Vector2(40, 0), Vector2(38, 0)
        end,
        rect = function(g, pos, size, c)
            if fake.raise then error(fake.raise) end
            log('rect', pos.x, pos.y, pos.z, size.x, size.y, c.a, c.r, c.g, c.b)
            return 'rect' .. #calls -- engine ids need not be numbers
        end,
        update_rect = function(g, id, pos, size, c) log('update_rect', id, pos.x, pos.y, pos.z, size.x, size.y, c.a, c.r) end,
        text = function(g, text, font, size, material, pos, c)
            log('text', text, font.hex, size, material.hex, pos.x, pos.y, pos.z, c.a, c.r, c.g, c.b)
            return {label = text}
        end,
        update_text = function(g, id, text, font, size, material, pos, c) log('update_text', id.label, text, pos.x) end,
    },
    Material = {
        set_scalar = function(m, slot, v) log('set_scalar', slot.hex, v) end,
        set_vector2 = function(m, slot, v) log('set_vector2', slot.hex, v.x, v.y) end,
        set_vector4 = function(m, slot, c) log('set_vector4', slot.hex, c.a, c.r, c.g, c.b) end,
        set_texture = function(m, slot, t) log('set_texture', slot.hex, t.hex) end,
    },
    Vector2 = Vector2,
    Vector3 = function(x, y, z) return {x = x, y = y, z = z} end,
    Color = function(a, red, green, blue) return {a = a, r = red, g = green, b = blue} end,
    IdString64 = {from_hex = function(hex) return {hex = hex} end},
}

-- The game's update below the Lua part: it counts, and its arguments and results must pass through unchanged.
local below = 0
local function game_update(dt, extra)
    below = below + 1
    return 'from below', dt, extra
end
local function new_env() return {update = game_update} end
local function load_part(options) assert(loadfile(SOURCE))(options) end

local function same(call, ...)
    local want = {...}
    if not call or #call ~= #want then return false end
    for i = 1, #want do
        local a, b = call[i], want[i]
        if type(b) == 'number' then
            if math.abs(a - b) > 1e-9 then return false end
        elseif a ~= b then return false end
    end
    return true
end

local env = new_env()

run('Declaration', function()
    local file = assert(io.open(SOURCE, 'rb'))
    local body = file:read('*a')
    file:close()
    check(body:match('^[^\n]*') == '-- HD2-Addon: mods/cowboybingus/vpm_forecast_panel', 'the first line declares the addon')
    check(not body:find('\r', 1, true) and body:byte(1) == 45, 'LF line endings, no byte-order mark')
    for _, banned in ipairs({'WriteProcessMemory', 'VirtualProtect', 'VirtualAlloc', 'CreateRemoteThread', 'jit.flush',
        'jit.opt', 'jit.attach'}) do
        check(not body:find(banned, 1, true), 'names no ' .. banned)
    end
end)

run('Attaches', function()
    load_part({env = env, engine = engine, dll = 'kyc_lua_probe.dll'})
    check(env.VpmForecastPanel and env.VpmForecastPanel.state == 'attached', 'attached to the DLL')
    check(env.update ~= game_update, 'its update is installed over the game\'s')
    check(probe.probe_route() == 0, 'the DLL takes it only on the component\'s frame')
    check(probe.probe_tick(ADOPT) == 1 and probe.probe_route() == 1, 'adopted as the panel\'s route')
    check(probe.probe_tick(ADOPT) == 0, 'once')
    local again = env.update
    load_part({env = env, engine = engine, dll = 'kyc_lua_probe.dll'})
    check(env.update == again, 'a second copy installs nothing')
end)

run('IdleFrames', function()
    reset_calls()
    below = 0
    local a, b, c
    for i = 1, 100 do a, b, c = env.update(0.016, i) end -- the first frames grow the Lua stack once
    collectgarbage()
    collectgarbage('stop')
    for i = 101, 200 do a, b, c = env.update(0.016, i) end -- and the collector's own first counts settle
    local before = collectgarbage('count')
    for i = 201, 10000 do a, b, c = env.update(0.016, i) end
    local grown = collectgarbage('count') - before
    collectgarbage('restart')
    check(#calls == 0 and counts[0] == 0 and counts[1] == 0, 'no engine call, no draw')
    check(below == 10000 and a == 'from below' and b == 0.016 and c == 10000, 'the game\'s update runs, arguments and results unchanged')
    check(grown == 0, 'no allocation on idle frames (' .. grown .. ' KB)')
end)

run('ShowDraws', function()
    reset_calls()
    check(probe.probe_tick(SHOW) == 1 and probe.probe_work() == 1, 'a new forecast sets work')
    check(#calls == 0, 'the frame itself makes no engine call')
    env.update(0.016)
    check(counts[0] == 1 and counts[3] == 1 and probe.probe_work() == 0, 'one apply drew it; work is done')
    check(r[0] > 0 and r[1] == 3 and r[2] == r[0] and r[3] ~= r[0] and r[4] ~= r[3], 'main world and world list as stable refs')
    check(r[5] > 0 and r[6] == 1 and r[7] == 1 and r[8] == 2560 and r[9] == 1440, 'GUI, material and window size')
    check(r[10] == 7 and r[11] == -1 and r[12] == 40 and r[13] == 38, 'text extents: all three, by bits')
    check(r[14] == 1 and r[15] == 2 and r[16] == 3, 'rectangle and text ids per GUI')
    check(math.abs(r[17] - 1 / 60) < 1e-12 and r[18] == 100, 'the frame\'s dt and anchor reach the panel')
    local want = {
        {'main_world'}, {'worlds'}, {'create', 'ui', 'scale', 1, 1}, {'material', 1, '1111222233334444'},
        {'set_scalar', '8035c26600000000', 0.25}, {'set_vector2', 'e13777ce00000000', 1, -1},
        {'set_vector4', '7701209e00000000', 0, 0, 0, 0}, {'set_texture', '88bac99b00000000', 'fedcba9876543210'},
        {'resolution'}, {'extents', 'AB\195\169', '0123456789abcdef', 18}, {'rect', 10, 20, 1012, 30, 40, 255, 1, 2, 3},
        {'update_rect', 'rect11', 11, 21, 1013, 31, 41, 204, 4},
        {'text', 'Hello', '0123456789abcdef', 13, '1111222233334444', 5, 6, 1014, 255, 240, 243, 245},
        {'update_text', 'Hello', 'World', 7}, {'rect', 10, 20, 1012, 30, 40, 255, 7, 8, 9},
    }
    check(#calls == #want, 'exactly the scripted engine calls (' .. #calls .. ')')
    for i, call in ipairs(want) do check(same(calls[i], unpack(call)), 'engine call ' .. i .. ': ' .. call[1]) end
    reset_calls()
    env.update(0.016)
    check(#calls == 0 and counts[0] == 1, 'the next frame does nothing')
end)

run('StillPanel', function()
    reset_calls()
    local shows = counts[0]
    for _ = 1, 29 do
        probe.probe_tick(SHOW)
        env.update(0.016)
    end
    check(counts[0] == shows, 'the same forecast at the same place: no apply for 29 frames')
    probe.probe_tick(SHOW)
    check(probe.probe_work() == 1, 'the 30th frame checks the worlds and window again')
    env.update(0.016)
    check(counts[0] == shows + 1 and probe.probe_work() == 0, 'one apply')
    probe.probe_tick(SHOW_MOVED)
    env.update(0.016)
    check(counts[0] == shows + 2 and r[18] == 200, 'the native panel moved: drawn at once')
    probe.probe_tick(SHOW_OTHER)
    env.update(0.016)
    check(counts[0] == shows + 3, 'another forecast: drawn at once')
    probe.probe_scroll(1)
    for _ = 1, 5 do
        probe.probe_tick(SHOW_OTHER)
        env.update(0.016)
    end
    check(counts[0] == shows + 8, 'a scrolling headline: every frame')
    probe.probe_scroll(0)
    probe.probe_tick(SHOW_OTHER)
    env.update(0.016)
    probe.probe_tick(SHOW_OTHER)
    env.update(0.016)
    check(counts[0] == shows + 8, 'still again: no apply')
    probe.probe_tick(SUSPEND)
    env.update(0.016)
    check(counts[2] == 1, 'waiting keeps the frame: one apply')
    check(#calls == 0, 'the scripted panel drew nothing more')
end)

run('Clears', function()
    reset_calls()
    check(probe.probe_tick(CLEAR) == 1 and probe.probe_work() == 1, 'hiding sets work')
    env.update(0.016)
    check(#calls == 1 and same(calls[1], 'destroy', 'ui', 1), 'the GUI is destroyed in its world')
    check(probe.probe_tick(CLEAR) == 1 and probe.probe_work() == 0, 'hiding again: nothing to do')
    env.update(0.016)
    check(#calls == 1, 'and nothing done')
end)

run('EngineErrors', function()
    reset_calls()
    fake.raise = 'boom'
    check(probe.probe_tick(SHOW) == 1, 'the show is requested')
    env.update(0.016)
    fake.raise = nil
    local result = probe.probe_tick(SHOW)
    local why = ffi.string(probe.probe_error())
    check(result == -1, 'the draw\'s error reaches the frame on its next show')
    check(why:find('engine Gui: ', 1, true) == 1 and why:find('boom', 1, true) ~= nil, 'as a failure naming the engine\'s error: ' .. why)
    check(probe.probe_tick(CLEAR) == 1, 'the frame hides')
    env.update(0.016)
    check(calls[#calls][1] == 'destroy', 'and the GUI goes')
end)

run('NoWorldList', function()
    reset_calls()
    fake.no_list = true
    probe.probe_tick(SHOW)
    env.update(0.016)
    check(probe.probe_tick(SHOW) == 0 and probe.probe_work() == 1, 'not drawn: retried next frame')
    check(r[1] == -1 and r[5] == 0, 'no list: -1, and no GUI made')
    fake.no_list = nil
    env.update(0.016)
    check(probe.probe_tick(SHOW) == 1 and r[5] > 0, 'drawn once the worlds are back')
    probe.probe_tick(CLEAR)
    env.update(0.016)
end)

run('RefusedVersion', function()
    local lib = env.VpmForecastPanel.lib
    check(lib.vpm_kyc_lua_attach(2, ffi.sizeof('vpm_kyc_call'), env.VpmForecastPanel.callback) == nil, 'version 2 is refused')
    check(lib.vpm_kyc_lua_attach(1, ffi.sizeof('vpm_kyc_call') - 8, env.VpmForecastPanel.callback) == nil, 'another call size is refused')
    check(probe.probe_tick(ADOPT) == -1, 'the frame sees the refusal once')
    check(ffi.string(probe.probe_absent()):find('version 1 with a', 1, true) ~= nil, 'and can say why')
end)

run('NoDll', function()
    local other = new_env()
    load_part({env = other, engine = engine, dll = 'no_such_probe.dll'})
    check(other.VpmForecastPanel.state:find('waiting', 1, true) == 1, 'waits for the DLL')
    below = 0
    for _ = 1, 60 * 60 do other.update(0.016) end
    check(other.VpmForecastPanel.state:find('gave up', 1, true) ~= nil, 'gives up after 60 tries, one every 60 frames')
    check(below == 3600, 'the game\'s update runs every frame')
end)

run('NoEngine', function()
    local other = new_env()
    load_part({env = other, engine = {}, dll = 'kyc_lua_probe.dll'})
    check(other.VpmForecastPanel.state == 'off: the game GUI is unavailable' and other.update == game_update, 'no GUI: nothing installed')
    local bare = {}
    load_part({env = bare, engine = engine, dll = 'kyc_lua_probe.dll'})
    check(bare.VpmForecastPanel.state == 'off: the game update is unavailable' and bare.update == nil, 'no update: nothing installed')
end)

print(checks .. ' checks, ' .. failures .. ' failed')
os.exit(failures == 0 and 0 or 1)
