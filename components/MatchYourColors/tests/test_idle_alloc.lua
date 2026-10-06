-- Match Your Colors: idle frames allocate nothing, the 2-second checks included. The JIT is off for this whole
-- process before any code runs, so the interpreter's behavior is measured: it boxes values that compiled code
-- may keep in registers, so no allocation here means none in compiled code either (and no trace objects or
-- JIT internals blur the count). Uses tests/test_addon.lua's simulated game.
-- Usage: luajit tests/test_idle_alloc.lua <repository root>
jit.off() -- lint-ok: R5 test process only, never in the game
local root = assert(arg and arg[1], 'usage: test_idle_alloc.lua <repository root>')
rawset(_G, 'MYC_TEST_SETUP_ONLY', true) -- lint-ok: R8 test process only
local setup = dofile(root .. '/tests/test_addon.lua')
rawset(_G, 'MYC_TEST_SETUP_ONLY', nil) -- lint-ok: R8 test process only
local Fake = dofile(root .. '/tests/fake_game.lua')
local passed = 0
-- Cases: no preview slot; a preview slot; the UI preview system with nothing shown; the UI preview shown.
local CASES = {{}, {previews = true}, {ui = true}, {ui = true, shown = true}}
for _, case in ipairs(CASES) do
    local w = setup({previews = case.previews, ui = case.ui})
    if case.shown then
        w.engine.unit(0x300, '962a946e964ebc40')
        Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    end
    w.frames(12)
    local step = w.instance.step
    for _ = 1, 360 do step() end -- three periodic checks: one-time table growth happens here
    collectgarbage('collect') -- lint-ok: R4 test process only, never in the game
    for _ = 1, 240 do step() end -- a collection may shrink the Lua stack; the next deep call grows it once
    collectgarbage('stop') -- lint-ok: R4 test process only
    local before = collectgarbage('count') -- lint-ok: R4 test process only
    for _ = 1, 2400 do step() end -- 20 periodic checks
    local grown = collectgarbage('count') - before -- lint-ok: R4 test process only
    collectgarbage('restart') -- lint-ok: R4 test process only
    assert(grown == 0, string.format('2400 idle frames (case %d) allocated %.0f bytes', passed + 1, grown * 1024))
    passed = passed + 1
end
print('PASS test_idle_alloc (' .. passed .. ' checks: 2400 idle frames each, with and without a preview slot, '
    .. 'with the UI preview hidden and shown)')
