-- Shared harness of tests/test_budget.lua, tests/test_pending.lua and
-- tests/test_panel_budget.lua: the real installer, mission and presentation
-- readers, roster and model over synthetic memory, read through an
-- allocation-free fake of the game's reader. The GUI surface is stubbed, or
-- the real panel draws through an allocation-free fake engine (H.engine).
-- Also measures garbage per frame with the collector stopped, interpreted and
-- compiled.
--   local H = assert(loadfile(source .. '/../tests/session.lua'))()(source)
local ffi = require('ffi')

return function(source)
    local H = {}
    local function load(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
    local budget = assert(loadfile(source .. '/../tests/frame_budget.lua'))()
    local memory = assert(loadfile(source .. '/../tests/fixtures/memory.lua'))()
    local resolve, mission, presentation = load('resolve'), load('mission'), load('presentation')
    -- The vendored runtime core (the update guard), and a read side whose build
    -- check accepts this game: module hashing is the runtime's own, tested there.
    local runtime = load('bingus_runtime')
    H.supported = {new = function() return {verify_build = function() return true end} end}
    local roster, roster_data, model = load('roster'), load('roster_data'), load('model')
    local text = load('bingus_text')
    local english = assert(loadfile(source .. '/../locales/en.lua'))()
    H.budget, H.memory, H.text = budget, memory, text

    function H.word(n) return ffi.string(ffi.new('uint32_t[1]', n), 4) end
    function H.qword(n) return ffi.string(ffi.new('uint64_t[1]', n), 8) end
    local word, qword = H.word, H.qword

    -- Synthetic memory in 4 KB pages, with the bytes a fixture defines. Reading
    -- an undefined byte fails the test; bytes marked unreadable make the read
    -- fail the way ReadProcessMemory does.
    local function address_space(fixtures)
        local pages, space = {}, {}
        local function page_of(at)
            local number = math.floor(at / 4096)
            local page = pages[number]
            if not page then
                page = {bytes = ffi.new('uint8_t[4096]'), defined = ffi.new('uint8_t[4096]')}
                pages[number] = page
            end
            return page
        end
        function space.put(address, bytes)
            for i = 1, #bytes do
                local at = address + i - 1
                local page = page_of(at)
                page.bytes[at % 4096], page.defined[at % 4096] = bytes:byte(i), 1
            end
        end
        -- Marks [address, address + size) unreadable (2) or readable again (1).
        function space.readable(address, size, yes)
            for at = address, address + size - 1 do page_of(at).defined[at % 4096] = yes and 1 or 2 end
        end
        -- Copies size bytes at address to destination[offset ...], allocating
        -- nothing. False when a byte is unreadable.
        function space.copy(address, size, destination, offset)
            for i = 0, size - 1 do
                local at = address + i
                local page, index = pages[math.floor(at / 4096)], at % 4096
                local state = page and page.defined[index]
                if state == 2 then return false end
                if state ~= 1 then error(string.format('Unexpected read 0x%x + %d', address, size)) end
                destination[offset + i] = page.bytes[index]
            end
            return true
        end
        function space.pointer(address)
            local bytes = ffi.new('uint8_t[8]')
            assert(space.copy(address, 8, bytes, 0))
            local value = 0
            for i = 7, 0, -1 do value = value * 256 + bytes[i] end
            return value
        end
        for _, fixture in ipairs(fixtures) do
            for _, block in ipairs(fixture.blocks) do space.put(block.address, block.bytes) end
        end
        return space
    end
    -- The game's reader over a space: number addresses; a string, or the bytes
    -- copied into a caller buffer; nil when they cannot all be read.
    local function reader(space, game)
        local api = {}
        function api.read(address, size, into, offset)
            assert(type(address) == 'number', 'Addresses are numbers')
            if into then
                offset = offset or 0
                if size <= 0 or offset < 0 or offset + size > into.size then return nil end
                return space.copy(address, size, into.data, offset) or nil
            end
            local bytes = ffi.new('uint8_t[?]', size)
            if not space.copy(address, size, bytes, 0) then return nil end
            return ffi.string(bytes, size)
        end
        function api.module() return game end
        function api.module_hash() return 'supported' end
        return api
    end

    -- A fake of the engine calls the panel makes that allocates nothing once
    -- set up: every call returns a value made in advance, and is counted by
    -- name ('Application.worlds', 'Gui.update_text', ...) in `counts`. Text is
    -- half its size wide per byte. `worlds` is the world list: main, the UI
    -- world (the first non-main world, the only one a GUI may go to) and one
    -- more.
    function H.engine()
        local counts, ids = {}, 0
        local main, ui, other = {}, {}, {}
        local gui, material, colour, v2, v3 = {}, {}, {}, {}, {}
        local lo, hi, caret = {x = 0}, {x = 0}, {x = 0}
        local e = {Application = {}, World = {}, Gui = {}, Material = {}, IdString64 = {}, Vector2 = {},
            worlds = {main, ui, other}, ui = ui}
        local function count(name) counts[name] = (counts[name] or 0) + 1 end
        function e.Application.main_world() count('Application.main_world') return main end
        function e.Application.worlds() count('Application.worlds') return e.worlds end
        function e.World.create_screen_gui(world)
            count('World.create_screen_gui')
            assert(world == e.ui, 'A GUI only goes to the UI world')
            return gui
        end
        function e.World.destroy_gui(world, g)
            count('World.destroy_gui')
            assert(g == gui and world ~= main)
        end
        function e.Gui.material() count('Gui.material') return material end
        function e.Gui.resolution() count('Gui.resolution') return 2560, 1440 end
        function e.Gui.text_extents(_, value, _, size)
            count('Gui.text_extents')
            local width = #value * size * 0.5
            lo.x, hi.x, caret.x = -0.08 * size, width + 0.04 * size, width
            return lo, hi, caret
        end
        function e.Gui.rect() count('Gui.rect') ids = ids + 1 return ids end
        function e.Gui.update_rect() count('Gui.update_rect') end
        function e.Gui.text() count('Gui.text') ids = ids + 1 return ids end
        function e.Gui.update_text() count('Gui.update_text') end
        for _, name in ipairs({'set_scalar', 'set_vector2', 'set_vector4', 'set_texture'}) do
            local counted = 'Material.' .. name
            e.Material[name] = function() count(counted) end
        end
        function e.IdString64.from_hex(hex) count('IdString64.from_hex') return hex end
        setmetatable(e.Vector2, {__call = function() count('Vector2') return v2 end})
        function e.Vector2.x(v) count('Vector2.x') return v.x end
        function e.Vector3() count('Vector3') return v3 end
        function e.Color() count('Color') return colour end
        return e, counts
    end

    -- One installed mod over one address space. The hosted operation frame is
    -- visible on the map (or, for a client, the planet frame of a joinable
    -- hover); the briefing reuses the loaded mission descriptor through the
    -- briefing owner record. With `engine` (H.engine), the real panel draws
    -- through it and is s.surface; otherwise the GUI surface is stubbed.
    function H.session(kind, engine)
        local mission_fixture = memory.mission(kind == 'client' and 'join' or 'host')
        local panel_fixture = memory.presentation(kind == 'client' and 'join' or 'map')
        assert(mission_fixture.game == panel_fixture.game)
        local game = mission_fixture.game
        local space = address_space({mission_fixture, panel_fixture})
        local api = reader(space, game)
        local s = {space = space, game = game, fixture = mission_fixture, counts = budget.wrap(api), published = 0}
        local screen_state = space.pointer(game + 0x347ce28) + 0x429c
        local manager = space.pointer(game + 0x3326e68)
        s.manager, s.owner = manager, space.pointer(manager + 25224 + 8)
        s.board, s.root = space.pointer(game + 0x347cee8), space.pointer(game + 0x3326340)
        s.screen_state = screen_state
        if kind ~= 'client' then space.put(s.owner + 349072, memory.widget(512, 768.8333, 533, 489)) end
        local controller = space.pointer(s.root + 0xae288)
        s.controller = controller
        space.put(manager + 26184, word(1))
        space.put(manager + 26192, qword(0x5a000000) .. word(235) .. word(0))
        local loaded = ffi.new('uint8_t[200]')
        assert(space.copy(controller + 8, 200, loaded, 0))
        space.put(0x5a000000 + 1072, ffi.string(loaded, 200))
        function s.show_screen(top) space.put(screen_state, word(top) .. string.rep('\0', 16) .. word(1)) end
        -- The game's Text Language: settings +212 indexes the language records; record 11 is zh-CN.
        local settings = space.pointer(game + text.GAME.settings)
        space.put(settings + text.GAME.index, word(11))
        space.put(game + text.GAME.table + 8 * 11, qword(0x5b000000))
        space.put(0x5b000000 + 8, qword(0x5b000100))
        space.put(0x5b000100, 'zh-CN' .. string.rep('\0', 11))
        -- Campaign spawn weights on the session's planet (category-72 rows 501
        -- and 502) and a war effect in scope everywhere.
        function s.add_weights()
            local defs, data = space.pointer(game + 0x347cd98), s.board + 1053752
            local function float(n) return ffi.string(ffi.new('float[1]', n), 4) end
            local function weight_row(id, family, factor)
                return word(id) .. word(72) .. word(9000 + id) .. string.rep('\0', 12) .. word(13) .. word(family)
                    .. word(0) .. word(2) .. word(math.floor(factor * 100)) .. float(factor) .. word(1)
            end
            local first = ffi.new('uint8_t[52]')
            assert(space.copy(defs, 52, first, 0))
            space.put(defs + 53248, word(3))
            space.put(defs, ffi.string(first, 52) .. weight_row(501, 0xbfb1567b, 5) .. weight_row(502, 0x72c5564a, 0.5))
            space.put(data + 304 * 76 + 286952, word(501) .. word(502) .. string.rep('\0', 120) .. word(2))
            space.put(space.pointer(game + 0x346d518), string.char(15) .. string.rep('\0', 3) .. word(0x72c5564a)
                .. float(0.25) .. string.rep('\0', 68) .. word(1) .. string.char(3, 0, 0, 0) .. word(0) .. word(0)
                .. string.rep('\0', 260))
        end
        -- Three level tags (native 12, 13 and 24): a headline wider than the
        -- box; off again with `false`.
        function s.long_headline(on)
            space.put(space.pointer(controller + 648) + 9160276, word(12) .. word(13) .. word(24) .. word(on == false and 0 or 3))
        end
        local surface = {}
        function surface:show(m, _, anchor) s.shown, s.anchor = m, anchor s.published = s.published + 1 return true end
        function surface:suspend() end
        function surface:clear() s.shown = nil end
        local panel = {new = function() return surface end}
        if engine then
            local real = assert(loadfile(source .. '/panel.lua'))(text)
            panel = {new = function(e) s.surface = real.new(e) return s.surface end}
        end
        s.env = setmetatable({stingray = engine or {Gui = {}, World = {}}, print = function() end, os = {}, io = io},
            {__index = _G})
        s.env._G = s.env
        -- The game's update below the mod, which the runtime guard wraps.
        s.env.update = function() end
        -- The roster's calls, with the weights of the last one.
        s.roster_calls = 0
        local counted = setmetatable({new = function(data)
            local forecasts = roster.new(data)
            local report = forecasts.report
            function forecasts.report(self, snapshot, zone, war)
                s.roster_calls, s.zone, s.war = s.roster_calls + 1, zone, war
                return report(self, snapshot, zone, war)
            end
            return forecasts
        end}, {__index = roster})
        local install = load('install')
        setfenv(install, s.env)({create_api = function() return api end, mission = mission, resolve = resolve,
            roster = counted, roster_data = roster_data, model = model, panel = panel, presentation = presentation,
            text = text, locales = {en = english, bundled = {}}, runtime = runtime, runtime_memory = H.supported,
            build = {revision = 'budget', game_sha256 = 'supported', exe_sha256 = 'supported'}})
        s.guard = s.env.EnemyIntelligence.guard
        return s
    end

    -- Garbage per frame with the collector stopped. A full collection shrinks
    -- LuaJIT's shared string buffer, and the first string built after it grows
    -- the buffer back (64 bytes, once per collection), so the frame right after
    -- the collection is not counted. Any trace event (start, stop, abort,
    -- flush) marks JIT work, which allocates.
    local compiling = 0
    jit.attach(function() compiling = compiling + 1 end, 'trace') -- lint-ok: R5 test only: tells JIT work from frame garbage
    local function garbage(s, frames, dt)
        collectgarbage('collect') collectgarbage('stop') -- lint-ok: R4 test only: counts garbage with the collector stopped
        s.env.update(dt)
        local start, events = collectgarbage('count'), compiling
        for _ = 1, frames do s.env.update(dt) end
        local bytes = (collectgarbage('count') - start) * 1024
        collectgarbage('restart') -- lint-ok: R4 test only: restarts the collector it stopped
        return bytes / frames, compiling == events
    end
    -- The interpreter alone: traces compiled so far are flushed first, since a
    -- trace's side exit can rebuild objects the trace never allocated. The least
    -- of three 30-frame windows: garbage made every frame shows in each, while
    -- a one-off regrowth after the collection (once seen right after the first
    -- collection of a run) does not.
    function H.interpreted(s, dt)
        jit.flush() jit.off() -- lint-ok: R5 test only: measures the interpreter
        for _ = 1, 3 do s.env.update(dt) end
        local least = math.huge
        for _ = 1, 3 do least = math.min(least, (garbage(s, 30, dt))) end
        jit.on() -- lint-ok: R5 test only: restores the JIT
        return least
    end
    -- Compiled: the least of five 60-frame windows in which the JIT did nothing
    -- (garbage made every frame shows in each of them).
    function H.compiled(s, dt)
        for _ = 1, 300 do s.env.update(dt) end
        local least, windows = math.huge, 0
        for _ = 1, 60 do
            local bytes, quiet = garbage(s, 60, dt)
            if quiet then least, windows = math.min(least, bytes), windows + 1 end
            if windows == 5 then return least end
        end
        error('the JIT never settled')
    end
    return H
end
