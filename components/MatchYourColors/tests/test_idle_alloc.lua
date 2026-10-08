-- Match Your Colors: idle frames allocate nothing, the 2-second checks included. The JIT is off for this whole
-- process before any code runs, so the interpreter's behavior is measured: it boxes values that compiled code
-- may keep in registers, so no allocation here means none in compiled code either (and no trace objects or
-- JIT internals blur the count). Uses tests/test_addon.lua's simulated game.
-- With Sync With Mod Users on, frames between lobby polls allocate nothing either (another mod user's Helldiver
-- recolored included: its unit watch and binding check); a poll allocates a few small boxes and is bounded here.
-- Usage: luajit tests/test_idle_alloc.lua <repository root>
jit.off() -- lint-ok: R5 test process only, never in the game
local root = assert(arg and arg[1], 'usage: test_idle_alloc.lua <repository root>')
rawset(_G, 'MYC_TEST_SETUP_ONLY', true) -- lint-ok: R8 test process only
local setup = dofile(root .. '/tests/test_addon.lua')
rawset(_G, 'MYC_TEST_SETUP_ONLY', nil) -- lint-ok: R8 test process only
local Fake = dofile(root .. '/tests/fake_game.lua')
local passed = 0
-- Bytes a lobby poll may allocate (measured: the boxed lobby handle and pointers PlayFab's calls return, the
-- other players' records when someone shares). Polls run once every 120 frames.
local POLL_BYTES = 2048
-- The Lua stack is part of the counted memory: a GC step halves it when it is mostly unused (lj_state_shrinkstack)
-- and the next deep call (the 2-second check) doubles it again, a one-time 0.5-1 KB that lands in the measured frames
-- or not depending on when the warm-up's GC steps ran. Recursing this deep just before the GC stops leaves the stack
-- far larger than any frame needs, so only the mod's own allocations are counted.
local STACK_DEPTH = 200
local function grow_stack(depth)
    if depth == 0 then return 0 end
    return grow_stack(depth - 1) + 1 -- not a tail call: one stack frame per level
end
-- Cases: no preview slot; a preview slot; the UI preview system with nothing shown; the UI preview shown; sync on
-- alone in the lobby; sync on with another mod user's Helldiver recolored; Recolor Cape on with the UI preview shown
-- (the cape recolored on the avatar and the preview, its kit compared on every check).
local LOCAL_ID = 'C0FFEE5EED0001'
local CASES = {{}, {previews = true}, {ui = true}, {ui = true, shown = true},
               {lobby = {local_id = LOCAL_ID, members = {{id = LOCAL_ID}}}},
               {lobby = {local_id = LOCAL_ID, members = {{id = LOCAL_ID}, {id = '1234', value = '1|2|3|0'}}}},
               {ui = true, shown = true, capes = true}}
for _, case in ipairs(CASES) do
    local w = setup({previews = case.previews, ui = case.ui, lobby = case.lobby})
    if case.shown then
        w.engine.unit(0x300, '962a946e964ebc40')
        Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    end
    if case.capes then w.instance.set_option('recolor_cape', true) end
    w.frames(12)
    local step, state = w.instance.step, w.instance.state
    for _ = 1, 360 do step() end -- three periodic checks and polls (the value posted): one-time growth happens here
    collectgarbage('collect') -- lint-ok: R4 test process only, never in the game
    for _ = 1, 240 do step() end
    assert(grow_stack(STACK_DEPTH) == STACK_DEPTH)
    collectgarbage('stop') -- lint-ok: R4 test process only
    local grown, polls, poll_bytes = 0, 0, 0
    for _ = 1, 2400 do -- 20 periodic checks (and 20 polls with sync on)
        local next_sync, before = state.next_sync, collectgarbage('count') -- lint-ok: R4 test process only
        step()
        local bytes = (collectgarbage('count') - before) * 1024 -- lint-ok: R4 test process only
        if state.next_sync ~= next_sync then
            polls, poll_bytes = polls + 1, math.max(poll_bytes, bytes)
        else
            grown = grown + bytes
        end
    end
    collectgarbage('restart') -- lint-ok: R4 test process only
    assert(grown == 0, string.format('2400 idle frames (case %d) allocated %.0f bytes', passed + 1, grown))
    assert(polls == (case.lobby and 20 or 0) and poll_bytes <= POLL_BYTES,
           string.format('case %d: %d polls, at most %.0f bytes each', passed + 1, polls, poll_bytes))
    if case.lobby then
        assert(not case.lobby.members[2] or w.instance.remote.order[1], 'the other mod user is recolored')
        print(string.format('  sync case %d: a lobby poll allocated at most %.0f bytes', passed + 1, poll_bytes))
    end
    passed = passed + 1
end
print('PASS test_idle_alloc (' .. passed .. ' checks: 2400 idle frames each, with and without a preview slot, '
    .. 'with the UI preview hidden and shown, with sync on alone and with another mod user recolored, with Recolor '
    .. 'Cape on)')
