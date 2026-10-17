-- Holster Your Shield: the addon on a simulated game (tests/fake_game.lua). Every press case, re-stows and their
-- limit, refusals, the check of every move, kept addresses that move or die, the exact api calls of every
-- per-frame path (tests/frame_budget.lua), no allocation and no C types per idle frame. Runs in a LuaJIT 2.1 and
-- in the game's lua51.dll (tests/game_lua.py).
-- Usage: luajit tests/test_mod.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_mod.lua <repository root>')
local G = dofile(root .. '/tests/fake_game.lua')(root)
local budget, H, Holster = G.budget, G.H, G.Holster
local passed = 0
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ': ' .. tostring(err), 0) end
    passed = passed + 1
end

local function same(a, b)
    for name, n in pairs(a) do if b[name] ~= n then return false end end
    for name, n in pairs(b) do if a[name] ~= n then return false end end
    return true
end
-- Exact counts: the budget's limits are today's counts, and nothing else may be called.
local function expect_counts(frame, expected, label)
    budget.check(frame, expected, label)
    assert(same(frame, expected), label .. ': calls ' .. budget.describe(frame) .. ', expected '
        .. budget.describe(expected))
end
local function calls(api)
    local out = {}
    for _, c in ipairs(api.calls) do out[#out + 1] = table.concat(c, ',', 1, #c) end
    return table.concat(out, ' ')
end
local function clear(api) for i = #api.calls, 1, -1 do api.calls[i] = nil end end

-- A session with the ballistic shield in hand and the pistol (sidearm) out, settled on a check frame.
local function shield_in_hand(options)
    local w = G.world(options)
    w.set_row({backpack = G.SHIELD, held = G.SHIELD, slot = 2, mode = 2})
    local s = G.session(w, options)
    s.settle()
    clear(s.api)
    return s, w
end
-- One press: key down for a frame, then up.
local function press(s)
    s.w.press()
    local frame = s.frame()
    s.w.release()
    return frame
end
local HOLSTER = 'set_item,%d,1001,0 set_mode,%d,1001,1 send_held,-2,1001,3001,1'
local DRAW = 'set_item,%d,1001,3001 set_mode,%d,1001,2 send_held,-2,1001,3001,2'

check('a press with the shield in hand puts it on the back, with the game\'s own three calls', function()
    local s, w = shield_in_hand()
    press(s)
    assert(calls(s.api) == HOLSTER:format(w.inventory, w.inventory), calls(s.api))
    local row = w.row_state()
    assert(row.held == 0 and row.mode == 0, 'the row did not change')
    assert(s.instance.toggled, 'toggle not on')
    s.frame()
    assert(s.last('Shield to the back: done %(held 0, mode 0%)'), table.concat(s.lines, ' | '))
end)

check('the game draws the shield while toggled: stowed again on the next frame', function()
    local s, w = shield_in_hand()
    press(s)
    s.frames(3)
    clear(s.api)
    w.game_draws() -- a weapon switch back to a one-handed weapon
    s.frame()
    assert(calls(s.api) == HOLSTER:format(w.inventory, w.inventory), calls(s.api))
    s.frame()
    assert(s.last('after the game drew it: done'), table.concat(s.lines, ' | '))
    assert(s.instance.counts.restows == 1 and s.instance.toggled)
end)

check('a press while toggled brings the shield back to the hand with a one-handed weapon', function()
    local s, w = shield_in_hand()
    press(s)
    s.frames(2)
    clear(s.api)
    press(s)
    assert(calls(s.api) == DRAW:format(w.inventory, w.inventory), calls(s.api))
    local row = w.row_state()
    assert(row.held == G.SHIELD and row.mode == 2)
    assert(not s.instance.toggled)
    s.frame()
    assert(s.last('Shield to the hand: done'))
end)

check('a press while toggled with a two-handed weapon only ends the toggle', function()
    local s, w = shield_in_hand()
    press(s)
    s.frames(2)
    w.set_row({slot = 1}) -- the rifle; the shield is already on the back
    clear(s.api)
    press(s)
    assert(#s.api.calls == 0, calls(s.api))
    assert(not s.instance.toggled)
    assert(s.last('returns with the next one%-handed weapon'))
end)

check('a press with the shield on the back (two-handed weapon) keeps it there through the next draw', function()
    local s, w = shield_in_hand()
    w.set_row({held = 0, slot = 1, mode = 1})
    s.frames(2)
    clear(s.api)
    press(s)
    assert(#s.api.calls == 0 and s.instance.toggled, calls(s.api))
    assert(s.last('it stays there'))
    w.set_row({slot = 2})
    w.game_draws()
    s.frame()
    assert(calls(s.api) == HOLSTER:format(w.inventory, w.inventory), calls(s.api))
end)

check('carrying an objective: a press only flips the toggle; the shield is stowed after the drop draws it', function()
    local s, w = shield_in_hand()
    w.set_row({held = G.DRIVE, mode = 2})
    s.frames(2)
    clear(s.api)
    press(s)
    assert(#s.api.calls == 0 and s.instance.toggled)
    assert(s.last('carrying something else: the shield stays on the back'))
    s.frames(5)
    assert(#s.api.calls == 0, 'acted on the objective')
    w.game_draws() -- dropping the objective draws the shield
    s.frame()
    assert(calls(s.api) == HOLSTER:format(w.inventory, w.inventory), calls(s.api))
end)

check('the directional shield works the same way', function()
    local w = G.world()
    w.set_row({backpack = G.DIRECTIONAL, held = G.DIRECTIONAL, slot = 2, mode = 2})
    local s = G.session(w)
    s.settle()
    clear(s.api)
    press(s)
    assert(calls(s.api) == ('set_item,%d,1001,0 set_mode,%d,1001,1 send_held,-2,1001,3002,1'):format(w.inventory,
           w.inventory), calls(s.api))
end)

check('other backpacks: the key is never read and a press does nothing', function()
    local w = G.world()
    w.set_row({backpack = G.SUPPLY, held = 0, slot = 2, mode = 0})
    local s = G.session(w)
    s.settle()
    clear(s.api)
    w.press()
    local frame = s.frame()
    expect_counts(frame, {view = 1}, 'supply pack, key held')
    assert(#s.api.calls == 0 and not s.instance.toggled)
end)

check('a held key counts once; holding it does nothing more', function()
    local s, w = shield_in_hand()
    w.press()
    s.frames(10)
    w.release()
    assert(s.instance.counts.presses == 1, s.instance.counts.presses)
end)

check('re-stows stop after the limit: the toggle ends and the game keeps the shield', function()
    local s, w = shield_in_hand()
    press(s)
    for _ = 1, Holster.RESTOW_LIMIT + 3 do
        w.game_draws()
        s.frame()
    end
    assert(s.instance.counts.restows == Holster.RESTOW_LIMIT, s.instance.counts.restows)
    assert(not s.instance.toggled, 'still toggled')
    assert(s.last('drew the shield 7 times in 120 frames'), table.concat(s.lines, ' | '))
    local row = w.row_state()
    assert(row.held == G.SHIELD and row.mode == 2, 'the shield did not stay in hand')
    -- spread out over the window, re-stows go on
    local t, ws = shield_in_hand()
    press(t)
    for _ = 1, 10 do
        t.frames(Holster.RESTOW_WINDOW / 4)
        ws.game_draws()
        t.frame()
    end
    assert(t.instance.toggled and t.instance.counts.restows == 10, t.instance.counts.restows)
end)

check('a move the game does not take is logged as FAILED', function()
    local s = shield_in_hand({inert = true})
    press(s)
    s.frame()
    assert(s.last('Shield to the back: FAILED, the game did not take it %(held 3001, mode 2%)'),
           table.concat(s.lines, ' | '))
    assert(s.instance.counts.failed == 1)
end)

check('refusals: a press when the avatar is no longer owned here makes no call', function()
    local s, w = shield_in_hand()
    w.space.set32(w.avatar_record + 20, 0)
    press(s)
    assert(#s.api.calls == 0, calls(s.api))
    assert(s.last('Press refused: not an owned Helldiver avatar'), table.concat(s.lines, ' | '))
end)

check('a per-entity equipment copy is what the addon reads (the game\'s getter prefers it)', function()
    -- the copy flips the pistol to two-handed: a press while toggled must not draw
    local s, w = shield_in_hand({copies = {G.PISTOL}})
    press(s)
    s.frames(2)
    clear(s.api)
    press(s)
    assert(#s.api.calls == 0, calls(s.api))
    -- a copy of the shield with its type is still a shield
    local t, wt = shield_in_hand({copies = {G.SHIELD}})
    press(t)
    assert(calls(t.api) == HOLSTER:format(wt.inventory, wt.inventory), calls(t.api))
end)

check('rows moved by the game: the toggle survives, the new row is used', function()
    local s, w = shield_in_hand()
    press(s)
    s.frames(2)
    w.move_row(2)
    s.frames(Holster.CHECK_FRAMES)
    assert(s.instance.toggled, 'toggle lost: ' .. table.concat(s.lines, ' | '))
    clear(s.api)
    w.game_draws()
    s.frame()
    assert(calls(s.api) == HOLSTER:format(w.inventory, w.inventory), calls(s.api))
end)

check('a new Helldiver ends the toggle', function()
    local s, w = shield_in_hand()
    press(s)
    s.frames(2)
    w.respawn(1777)
    s.frames(Holster.CHECK_FRAMES)
    assert(not s.instance.toggled)
    assert(s.last('a new Helldiver'), table.concat(s.lines, ' | '))
end)

check('per-frame calls: exact counts on every path', function()
    -- no local player: nothing on ordinary frames, the resolution attempt on check frames
    local w = G.world()
    w.space.set32(w.players + 0x84, 0)
    local s = G.session(w)
    for _ = 1, Holster.CHECK_FRAMES - 1 do expect_counts(s.frame(), {}, 'no player, ordinary frame') end
    expect_counts(s.frame(), {u64 = 2, view = 1}, 'no player, check frame')
    -- a kept row without a shield: one read
    local t, wt = shield_in_hand()
    wt.set_row({backpack = G.SUPPLY, held = 0, mode = 0})
    t.frame() -- the backpack change reads the supply pack's settings once
    for _ = 1, 5 do expect_counts(t.frame(), {view = 1}, 'kept row, supply pack') end
    -- shield worn, no press: two reads
    local u = shield_in_hand()
    for _ = 1, 5 do expect_counts(u.frame(), {view = 2}, 'shield worn, idle') end
    -- the check frame adds the kept-address checks
    while (u.instance.frame + 1) % Holster.CHECK_FRAMES ~= 0 do u.frame() end
    expect_counts(u.frame(), {view = 5, u64 = 3}, 'shield worn, check frame')
    -- a press that holsters
    local v = shield_in_hand()
    v.w.press()
    expect_counts(v.frame(), {view = 25, u64 = 12, set_item = 1, set_mode = 1, send_held = 1}, 'press, holster')
    v.w.release()
    expect_counts(v.frame(), {view = 2}, 'the frame after: the check of the move')
    -- a press that draws
    v.frames(3)
    v.w.press()
    expect_counts(v.frame(), {view = 34, u64 = 15, set_item = 1, set_mode = 1, send_held = 1}, 'press, draw')
    v.w.release()
    -- a re-stow
    v.frames(3)
    press(v)
    v.frames(3)
    v.w.game_draws()
    expect_counts(v.frame(), {view = 25, u64 = 12, set_item = 1, set_mode = 1, send_held = 1}, 're-stow')
end)

check('idle frames allocate nothing and create no C types', function()
    local s = shield_in_hand()
    local step = s.instance.step
    -- As installed in the game: everything interpreted but the step's entry; the simulation's reads too, so a trace
    -- of test code is not counted as the addon's garbage.
    Holster.interpreted_but_step(s.instance)
    for _, fn in ipairs({s.w.space.copy, s.w.space.find}) do jit.off(fn, true) end
    for _ = 1, 200 do step() end -- warm up: the first frames intern what they use
    -- The smallest growth of five windows of 120 frames (four check frames each): an allocation of the addon's
    -- would show in every window; what LuaJIT does once (a new trace of this test's code, which the installed
    -- addon keeps interpreted) lands in one window only.
    local least
    for _ = 1, 5 do
        local kb = H.heap_peak(function() for _ = 1, 120 do step() end end)
        least = least and math.min(least, kb) or kb
    end
    assert(least == 0, 'idle frames allocated ' .. least .. ' KB')
    assert(H.ctype_growth(step) == 0, 'C types created per frame')
end)

-- The real adapter, on this process's memory: reads, and the prologue check of bind.
check('the in-game adapter reads, and bind refuses functions whose first bytes differ', function()
    local ffi = G.ffi
    local api = Holster.adapter()
    local buffer = ffi.new('uint8_t[?]', 0x240000)
    local base = tonumber(ffi.cast('uintptr_t', buffer))
    local game = base - 0x9AB000
    local function put(rva, hex)
        for i = 0, 15 do buffer[rva - 0x9AB000 + i] = tonumber(hex:sub(2 * i + 1, 2 * i + 2), 16) end
    end
    local L = Holster.LAYOUT
    for name, hex in pairs(Holster.PROLOGUES) do put(L[name], hex) end
    buffer[0] = 0x2A
    assert(api.view(base, 1) and api.bytes[0] == 0x2A, 'view')
    assert(api.u64(base) == 0x2A, 'u64')
    assert(api.view(0x10, 4) == false and api.u64(0x10) == nil, 'unreadable address read')
    assert(pcall(api.bind, game), 'bind refused the right bytes')
    assert(type(api.set_item) == 'function' and type(api.send_held) == 'function')
    buffer[L.set_mode - 0x9AB000] = 0xC3
    local ok, err = pcall(Holster.adapter().bind, game)
    assert(not ok and tostring(err):find('game function differs: set_mode'), tostring(err))
end)

check('install: refused outside the game, nothing hooked', function()
    _G.CowboyBingusModLoader = {api = 1, jit = {}, open_log = function()
        return {write = function() end, flush = function() end}
    end}
    local quiet = print
    print = function() end
    local env = {update = function() end}
    local memory = {module = function() return nil end}
    local instance = Holster.install({guard = function() error('no guard expected') end}, memory, {env = env})
    print = quiet
    _G.CowboyBingusModLoader = nil
    assert(instance == nil and env.HolsterYourShieldInstalled == nil)
end)

check('install: a matching build binds, reads the none ids and installs the guard', function()
    local w = G.world()
    w.space.set32(G.GAME + Holster.LAYOUT.none_item, 0)
    _G.CowboyBingusModLoader = {api = 1, jit = {}, open_log = function()
        return {write = function() end, flush = function() end}
    end}
    local quiet = print
    print = function() end
    local installed
    local runtime = {guard = function(options)
        return {install = function() installed = options; return {stop = function() end} end}
    end}
    local memory = {module = function() return G.GAME end, address = function(v) return v end,
                    verify_build = function() return true end}
    local api = G.api(w)
    api.bind = function() end
    local env = {}
    local instance = Holster.install(runtime, memory, {env = env, adapter = function() return api end})
    print = quiet
    _G.CowboyBingusModLoader = nil
    assert(instance and installed and installed.name == 'HolsterYourShield' and env.HolsterYourShieldInstalled)
    assert(instance.nones[0] and instance.none_item == 0)
end)

print(string.format('PASS: %d Holster Your Shield checks (%s)', passed, jit and jit.version or _VERSION))
