-- Expected transient states (screens being built or switched) never stop the
-- forecast. Each is held for 10,000 frames with the real installer, readers,
-- roster and model over synthetic memory (tests/session.lua): every frame
-- hides the forecast and reports the reason as v4.0 did, none counts toward
-- the 8-errors stop, the frames allocate nothing (interpreted and compiled),
-- and the forecast is back once the condition clears. The panel's own waits
-- (engine resources, window size) are held in tests/test_panel.lua.
local source = assert(arg[1])
local H = assert(loadfile(source .. '/../tests/session.lua'))()(source)
local word, qword = H.word, H.qword
local HOLD = 10000

-- Each condition: the screen it is met on, how to cause it and how to clear it.
local conditions = {
    {reason = 'Mission data unavailable', what = 'the UI screen stack cannot be read',
        set = function(s) s.space.readable(s.screen_state, 24, false) end,
        clear = function(s) s.space.readable(s.screen_state, 24, true) end},
    {reason = 'Mission data unavailable', what = 'the mission descriptor cannot be read',
        set = function(s) s.space.readable(s.board + 0x4168d0, 200, false) end,
        clear = function(s) s.space.readable(s.board + 0x4168d0, 200, true) end},
    {reason = 'Mission pointer unavailable', what = 'no root record yet',
        set = function(s) s.space.put(s.game + 0x3326340, qword(0)) end,
        clear = function(s) s.space.put(s.game + 0x3326340, qword(s.root)) end},
    {reason = 'Mission descriptor not ready', what = 'the descriptor has no faction yet',
        set = function(s) s.space.put(s.board + 0x4168d0 + 8, '\0') end,
        clear = function(s) s.space.put(s.board + 0x4168d0 + 8, '\2') end},
    {reason = 'No highlighted mission', what = 'no operation index',
        set = function(s) s.space.put(s.board + 1548960, word(120)) end,
        clear = function(s) s.space.put(s.board + 1548960, word(0)) end},
    {reason = 'No highlighted mission', what = 'the highlighted record is inactive',
        set = function(s) s.space.put(s.board + 1012352 + 52, '\0') end,
        clear = function(s) s.space.put(s.board + 1012352 + 52, '\1') end},
    {reason = 'Briefing descriptor unavailable', screen = 14, what = 'no briefing records',
        set = function(s) s.space.put(s.manager + 26184, word(0)) end,
        clear = function(s) s.space.put(s.manager + 26184, word(1)) end},
    {reason = 'Briefing owner unavailable', screen = 14, what = 'no owner record of the briefing',
        set = function(s) s.space.put(s.manager + 26192 + 8, word(236)) end,
        clear = function(s) s.space.put(s.manager + 26192 + 8, word(235)) end},
    {reason = 'Briefing owner unavailable', screen = 14, what = 'the owner record has no pointer yet',
        set = function(s) s.space.put(s.manager + 26192, qword(0)) end,
        clear = function(s) s.space.put(s.manager + 26192, qword(0x5a000000)) end},
    {reason = 'Presentation data unavailable', what = 'the native panel cannot be read',
        set = function(s) s.space.readable(s.owner + 349072, 164, false) end,
        clear = function(s) s.space.readable(s.owner + 349072, 164, true) end},
    {reason = 'Presentation owner unavailable', what = 'no menu manager yet',
        set = function(s) s.space.put(s.game + 0x3326e68, qword(0)) end,
        clear = function(s) s.space.put(s.game + 0x3326e68, qword(s.manager)) end},
    {reason = 'Native font is not ready', what = 'the body font is not loaded',
        set = function(s) s.space.put(s.game + 0x3772268, qword(0)) end,
        clear = function(s) s.space.put(s.game + 0x3772268, word(0xc5d17df2) .. word(0xb56d2aba)) end},
    {reason = 'Mission data unavailable', kind = 'client', what = 'the joinable list cannot be read',
        set = function(s) s.space.readable(s.board + 2044424, 20, false) end,
        clear = function(s) s.space.readable(s.board + 2044424, 20, true) end},
    {reason = 'Mission pointer unavailable', kind = 'client', what = 'no advertisement manager yet',
        set = function(s) s.space.put(s.game + 0x347ce80, qword(0)) end,
        clear = function(s) s.space.put(s.game + 0x347ce80, qword(0xb0000000)) end},
}

local sessions = {}
for _, condition in ipairs(conditions) do
    local kind = condition.kind or 'host'
    local s = sessions[kind] or H.session(kind)
    sessions[kind] = s
    local state = s.env.EnemyIntelligence
    local label = condition.reason .. ' (' .. condition.what .. ')'
    s.show_screen(condition.screen or 15)
    for _ = 1, 3 do s.env.update(0.11) end
    assert(s.shown and state.status:find('^visible'), 'The forecast shows before ' .. label)
    condition.set(s)
    local pending = state.pending
    for _ = 1, HOLD do s.env.update(0.016) end
    assert(state.status == 'hidden: ' .. condition.reason, label .. ': status ' .. state.status)
    assert(state.pending == pending + HOLD and state.guard.errors == 0 and state.failures == 0
        and not state.guard.first_failure,
        label .. ': a waiting frame never counts toward a stop')
    assert(not s.shown, label .. ': the forecast stays hidden while waiting')
    -- Waiting frames allocate nothing, interpreted or compiled.
    local slow, fast = H.interpreted(s, 0.016), H.compiled(s, 0.016)
    assert(slow == 0 and fast == 0, string.format('%s: %.1f B per waiting frame interpreted, %.1f compiled',
        label, slow, fast))
    condition.clear(s)
    for _ = 1, 3 do s.env.update(0.11) end
    assert(s.shown and state.status:find('^visible'), label .. ': the forecast is back once it clears')
end
-- A genuine error still counts: a descriptor that names an unknown mission type.
local s = sessions.host
s.show_screen(15)
for _ = 1, 3 do s.env.update(0.11) end
local state = s.env.EnemyIntelligence
s.space.put(s.board + 0x4168d0 + 26, word(300):sub(1, 2))
for _ = 1, 7 do s.env.update(0.016) end
assert(state.guard.errors == 7 and state.status:find('Unknown mission type'), 'a layout check failing counts')
s.env.update(0.016)
assert(state.status:find('^stopped after: 8 errors: '), 'its 8th error in a burst stops the mod')
print(string.format('PASS: %d expected transient states each held for %d frames: hidden with their reason, never '
    .. 'counted, no garbage interpreted or compiled, back once cleared; a failing layout check still stops at 8',
    #conditions, HOLD))
