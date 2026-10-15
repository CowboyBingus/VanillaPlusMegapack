-- Match Your Colors: Sync With Mod Users (src/sync.lua, src/remote.lua) in the frame step, against the simulated
-- game with a fake PlayFab lobby (tests/fake_game.lua): the shared value and its posts, the other members' values,
-- recoloring another mod user's Helldiver and giving it back, failures, the test build's loopback, and the exact
-- calls sync adds to each kind of frame (against a twin world without sync; tests/frame_budget.lua). The job is
-- tests/test_addon.lua's canned one.
-- Usage: luajit tests/test_sync.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_sync.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
rawset(_G, 'MYC_TEST_SETUP_ONLY', true) -- lint-ok: R8 test process only
local setup, requests, helpers = dofile(root .. '/tests/test_addon.lua')
rawset(_G, 'MYC_TEST_SETUP_ONLY', nil) -- lint-ok: R8 test process only
local Sync, Remote, Recolor = require('sync'), require('remote'), require('recolor')
require('sheets').attach(Recolor)
require('bindings').attach(Recolor)
local Fake = dofile(root .. '/tests/fake_game.lua')
local budget = dofile(root .. '/tests/frame_budget.lua')
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

-- The local player's peer 0x00c0ffee5eed0001 as PlayFab's entity id (%X: no zero padding); the remote player's
-- peer 0x1234. Their sync entry keys are the peers in 16 hex digits.
local LOCAL_ID, REMOTE_ID = 'C0FFEE5EED0001', '1234'
local LOCAL_KEY, REMOTE_KEY = '00c0ffee5eed0001', '0000000000001234'
local HELMET_LUT = '962a946e964ebc40'
local REMOTE_HELMET, REMOTE_ARMOR = 0x11111111, 0x22222222
-- helmet matches armor, complete sets kept, hoods recolored, no scheme: 'cbmyc2' (v1.5) and 'cbmyc' (v1.3-v1.4)
local SHARED, LEGACY = 'v=1;m=2;f=3;s=0;', '1|2|3|0'
local FAIL_HELMET = 0x0f0f0f0f -- the canned job fails for this helmet

local function world(members, extra)
    local options = {lobby = {local_id = LOCAL_ID, members = members}}
    for k, v in pairs(extra or {}) do options.lobby[k] = v end
    local w = setup(options)
    w.frames(5) -- the local Helldiver resolved and recolored
    return w
end
local function with_remote(value) return {{id = LOCAL_ID}, {id = REMOTE_ID, value = value or SHARED}} end
local function vanilla(w) return w.engine.vanilla[HELMET_LUT] end
local function logged(w, text)
    for _, line in ipairs(w.lines) do if line:find(text, 1, true) then return true end end
    return false
end
local function remote_unit_at(t, slot) return Fake.AVATARS + 5532272 + 440 + 220 + 40 * t + 4 * slot end
-- The calls frame a made beyond frame b (negative: fewer).
local function diff(a, b)
    local out = {}
    for k, v in pairs(a) do if v ~= (b[k] or 0) then out[k] = v - (b[k] or 0) end end
    for k, v in pairs(b) do if a[k] == nil then out[k] = -v end end
    return out
end
local same = helpers.same

check('natives: the buffers the post\'s update points into outlive collections (the 2026-10-07 crash: its keys array '
      .. 'was collected, its memory reused, and PlayFab read a garbage key pointer)', function()
    local ffi = require('ffi')
    local GARBAGE = 0x13fe3012e -- keys[0] in the user's dump
    local seen, callbacks = nil, {}
    local function lookup(name, ctype)
        local fn = function() return 0 end
        if name == 'PFLobbyPostUpdate' then
            fn = function(_, _, _, member_update)
                local u = ffi.cast('const MycMemberUpdate *', member_update)
                seen = {count = u.count, keys = {}, values = {}}
                for i = 0, math.min(u.count, 4) - 1 do
                    local k, v = u.keys[i], u.values[i]
                    local at = tonumber(ffi.cast('uintptr_t', k))
                    seen.garbage = seen.garbage or at == GARBAGE or at == 0
                    seen.keys[i + 1] = (at ~= GARBAGE and at ~= 0) and ffi.string(k) or nil
                    seen.values[i + 1] = v ~= nil and ffi.string(v) or false
                end
                return 0
            end
        end
        local cb = ffi.cast(ctype, fn)
        callbacks[#callbacks + 1] = cb
        return cb
    end
    local api = assert(Sync.natives(lookup))
    -- the game's heap after a big job: collections, then many arrays of its size holding a garbage pointer
    local junk = {}
    for round = 1, 3 do
        collectgarbage('collect')
        for i = 1, 4000 do
            local a = ffi.new('const char *[1]')
            a[0] = ffi.cast('const char *', GARBAGE)
            junk[(round - 1) * 4000 + i] = a
        end
    end
    assert(api.post(0, 0, SHARED, LEGACY) == 0, 'posted')
    assert(seen and not seen.garbage and seen.count == 2 and seen.keys[1] == 'cbmyc2' and seen.keys[2] == 'cbmyc'
           and seen.values[1] == SHARED and seen.values[2] == LEGACY,
           'the update still points at both keys and values: ' .. tostring(seen and seen.keys[1]))
    assert(api.post(0, 0, nil, nil) == 0 and seen.count == 2 and seen.values[1] == false and seen.values[2] == false,
           'removal: both keys without a value')
    for _, cb in ipairs(callbacks) do cb:free() end
end)

-- Every option combination (the FLAGS bits, Recolor Weapons included) for each mode and a few schemes.
local function each_options(fn)
    for mode = 1, 4 do
        for flags = 0, 31 do
            for _, scheme in ipairs({0, 1, 5, 12}) do
                local o = {mode = mode, scheme = scheme}
                for _, flag in ipairs(Sync.FLAGS) do o[flag[1]] = math.floor(flags / flag[2]) % 2 == 1 end
                fn(o, flags)
            end
        end
    end
end

check('encode and decode: every mode, option and scheme round trips through cbmyc2; cbmyc (v1.3-v1.4\'s) carries '
      .. 'the options those copies know, in their format', function()
    each_options(function(o, flags)
        local text = Sync.encode(o)
        assert(text == string.format('v=1;m=%d;f=%d;s=%d;', o.mode, flags, o.scheme), text)
        local back = assert(Sync.decode(text), text)
        for k, v in pairs(o) do assert(back[k] == v, text .. ': ' .. k) end
        local legacy = Sync.legacy(o)
        assert(legacy == string.format('1|%d|%d|%d', o.mode, flags % 16, o.scheme), legacy)
        local old = assert(Sync.decode(legacy), legacy)
        for k, v in pairs(o) do
            assert(old[k] == (k ~= 'recolor_weapons' and v or false), legacy .. ': ' .. k)
        end
    end)
end)

check('cbmyc2 is read forward-compatibly: unknown fields and flag bits are ignored, missing optional fields are off, '
      .. 'a higher format level, an unknown mode, a value cut short and anything malformed are refused', function()
    local o = assert(Sync.decode('s=5;x=hello;f=' .. (16 + 64 + 1024) .. ';m=3;v=1;zz_9=;'), 'any order, extra fields')
    assert(o.mode == 3 and o.scheme == 5 and o.recolor_weapons and not o.keep_sets and not o.recolor_cape,
           'known bits read, unknown bits (64, 1024) and fields ignored')
    o = assert(Sync.decode('v=1;m=2;'), 'flags and scheme optional')
    assert(o.mode == 2 and o.scheme == 0 and not o.recolor_weapons and not o.keep_sets, 'missing optional fields: off')
    for _, bad in ipairs({'v=2;m=2;f=3;s=0;', 'm=2;f=3;s=0;', 'v=1;f=3;s=0;', 'v=1;m=5;f=3;s=0;', 'v=1;m=0;',
                          'v=1;m=2;f=3;s=65;', 'v=1;m=2;f=-1;', 'v=1;m=2;f=3.5;', 'v=1;m=2;f=x;', 'v=1;m=2;f=3;s=0',
                          'v=1;m=2;f=3;s', 'v=1;m=2;;', 'v=1;m=2;f==3;', '=1;m=2;', ' v=1;m=2;', 'v=1;m=2.5;',
                          'v=1;m=2;f=4294967296;', '', string.rep('v=1;', 32), 'v=1|m=2'}) do
        assert(Sync.decode(bad) == nil, 'refused: ' .. bad)
    end
    for _, bad in ipairs({'2|2|3|0', '1|0|3|0', '1|5|3|0', '1|2|16|0', '1|2|3|65', '1|2|3', '1|2|3|0|9', ' 1|2|3|0',
                          '1|2|3|x', '1|-2|3|0'}) do
        assert(Sync.decode(bad) == nil, 'refused (cbmyc): ' .. bad)
    end
    assert(Sync.decode(nil) == nil and Sync.decode(12) == nil, 'no text')
end)

check('peer_of: entity ids without zero padding up to 16 digits, as exact halves', function()
    local low, high = Sync.peer_of(LOCAL_ID)
    assert(low == 0x5eed0001 and high == 0x00c0ffee, 'leading zero digits restored')
    low, high = Sync.peer_of(REMOTE_ID)
    assert(low == 0x1234 and high == 0, 'short id')
    low, high = Sync.peer_of('FfFfFfFfFfFfFfFf')
    assert(low == 0xffffffff and high == 0xffffffff, 'above 2^53, either case')
    for _, bad in ipairs({'', '12345678901234567', 'xyz', '12 34', '-1', '0x12'}) do
        assert(Sync.peer_of(bad) == nil, 'refused: ' .. bad)
    end
    assert(Sync.peer_of(nil) == nil, 'no id')
end)

check('always on (no option since 2026-10-07): shared and the others recolored from the start; a stale sync setting '
      .. 'changes nothing', function()
    local w = world(with_remote())
    w.instance.set_option('sync', false) -- the removed option's old value: refused
    assert(w.instance.state.syncing and w.instance.state.options.sync == nil, 'syncing, no option')
    w.frames(700) -- the first post once the lobby has stayed joined for STEADY_FRAMES
    assert(#w.lobby.posts == 1 and w.lobby.posts[1].text == SHARED and w.lobby.posts[1].legacy == LEGACY,
           'both values shared once, in one post')
    assert(w.bound(0x200)[1] ~= vanilla(w), 'the other mod user recolored')
end)

check('alone in the lobby: one lobby read every 120 frames, the value posted once the lobby is steady and 300 frames '
      .. 'after the last change, with PlayFab\'s own key of the local member',
      function()
    local w = world({{id = LOCAL_ID}})
    local polls = 0
    for _ = 1, 1200 do
        local f = w.frame()
        if f.members then
            polls = polls + 1
            -- the avatar's idle read, 7 for the lobby, the local member's key, id, type pointer and type: no property
            assert(f.read_into == 12 and f.members == 1 and not f.property, budget.describe(f))
        else
            assert(not f.post and not f.property, 'PlayFab only on poll frames: ' .. budget.describe(f))
        end
    end
    assert(polls == 10 and #w.lobby.posts == 1, polls .. ' polls, ' .. #w.lobby.posts .. ' posts')
    local post = w.lobby.posts[1]
    assert(post.text == SHARED and post.low == 0x89abcdef and post.high == 0xfedcba98, 'the value, the exact handle')
    assert(post.user == post.array and logged(w, 'Sync: shared ' .. SHARED .. '.'),
           'as the local member, by PlayFab\'s own key (its member list), never the game\'s copy')
    -- Two changes within the delay: one post, with the last value.
    w.instance.set_option('match_materials', true)
    w.frames(100)
    w.instance.set_option('scheme', 5)
    w.frames(600)
    assert(#w.lobby.posts == 2 and w.lobby.posts[2].text == 'v=1;m=2;f=7;s=5;' and w.lobby.posts[2].legacy == '1|2|7|5',
           'one post for both changes')
end)

check('squadmates on v1.3-v1.4 (cbmyc only) are recolored with their settings; a v1.5 squadmate\'s cbmyc2 wins over '
      .. 'its cbmyc; a player without the mod costs two lookups a poll, a v1.5 squadmate one', function()
    local old = world({{id = LOCAL_ID}, {id = REMOTE_ID, legacy = '1|2|5|0'}})
    old.frames(4)
    local last = requests[#requests]
    assert(old.bound(0x200)[1] ~= vanilla(old) and last.target == 'remote' and last.keep_sets == true
           and last.keep_hoods == true and last.materials == true, 'recolored with the older copy\'s settings')
    local new = world({{id = LOCAL_ID}, {id = REMOTE_ID, value = 'v=1;m=2;f=2;s=0;', legacy = '1|2|5|0'}})
    new.frames(4)
    last = requests[#requests]
    assert(last.keep_sets == false and last.keep_hoods == false and last.materials == false, 'cbmyc2 read, not cbmyc')
    local reads = {cbmyc2 = new.lobby.reads.cbmyc2, cbmyc = new.lobby.reads.cbmyc}
    new.frames(120)
    assert(new.lobby.reads.cbmyc2 - reads.cbmyc2 == 1 and new.lobby.reads.cbmyc == reads.cbmyc,
           'one lookup a poll for a v1.5 squadmate')
    local none = world({{id = LOCAL_ID}, {id = REMOTE_ID}})
    reads = {cbmyc2 = none.lobby.reads.cbmyc2, cbmyc = none.lobby.reads.cbmyc}
    none.frames(120)
    assert(none.lobby.reads.cbmyc2 - reads.cbmyc2 == 1 and none.lobby.reads.cbmyc - reads.cbmyc == 1,
           'two lookups a poll for a player without the mod')
    assert(none.bound(0x200)[1] == vanilla(none), 'not recolored')
end)

check('another mod user who shares is recolored with its own textures; the local Helldiver keeps its own', function()
    local w = world(with_remote())
    local own = w.bound(0x100)[1]
    w.frames(4) -- the poll (frame 6), the job over frames 7 and 8
    local theirs = w.bound(0x200)[1]
    assert(theirs ~= vanilla(w) and theirs ~= own, 'their helmet recolored with a texture of its own')
    for _, object in ipairs(w.bound(0x200)) do assert(object == theirs, 'every material of it') end
    assert(w.bound(0x100)[1] == own, 'the local helmet keeps its texture')
    local last = requests[#requests]
    assert(last.target == 'remote' and last.key == REMOTE_KEY and last.mode == Recolor.HELMET_FROM_ARMOR
           and last.helmet == REMOTE_HELMET and last.armor == REMOTE_ARMOR and last.body == 0, 'their kits')
    assert(last.keep_sets == true and last.keep_hoods == false and last.materials == false and last.scheme == 0,
           'their settings')
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' recolored, 2 materials (shared settings).'), 'logged')
end)

check('the calls sync adds: a lobby poll every 120 frames, one 120-byte read on 1 frame in 4, two reads every 30',
      function()
    local w, twin = world(with_remote()), setup({}) -- the twin: no lobby and no sync modules
    twin.frames(5)
    for _ = 1, 10 do w.frame() twin.frame() end -- recolored by frame 8
    local polls, watches, checks = 0, 0, 0
    for _ = 1, 1200 do
        local extra = diff(w.frame(), twin.frame())
        local frame = w.instance.state.frame
        local expected = {}
        if (frame - 5) % 120 == 0 then
            -- 7 for the lobby, 2 per member (key, id) and 2 for the local one's type, 1 for the other's value, 14 for
            -- the players' records; the value posted once the lobby has stayed joined for STEADY_FRAMES (first poll:
            -- frame 5, as frame 4 applies the local recolor)
            expected, polls = {members = 1, property = 1, read_into = 28, post = frame == 605 and 1 or nil}, polls + 1
        elseif frame % Remote.WATCH_FRAMES == 0 then
            expected, watches = {read_into = 1}, watches + 1
        elseif frame % 30 == 1 then
            expected, checks = {read_into = 2}, checks + 1 -- one runtime texture: two reads
        end
        assert(same(extra, expected), 'frame ' .. frame .. ': ' .. budget.describe(extra) .. ', expected '
               .. budget.describe(expected))
    end
    assert(polls == 10 and watches > 280 and checks == 40, polls .. ' polls, ' .. watches .. ' watches')
end)

check('stops sharing, then leaves: its own colors back at the next poll, textures back to the pool, no more reads',
      function()
    local w = world(with_remote())
    w.frames(4)
    local made = #w.engine.created
    w.lobby.members[2].value = nil
    w.frames(120)
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'restored') end
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' restored.') and not w.instance.remote.order[1], 'dropped')
    w.frames(8)
    assert(#w.instance.remote.retiring == 0, 'retired textures collected')
    w.lobby.members[2].value = SHARED
    w.frames(124)
    assert(w.bound(0x200)[1] ~= vanilla(w) and #w.engine.created == made, 'shared again: recolored from the pool')
    table.remove(w.lobby.members, 2)
    w.lobby.sync()
    w.frames(120)
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'left: restored') end
    w.frames(Sync.STEADY_FRAMES - 360) -- past the value's first post (the lobby steady)
    assert(#w.lobby.posts == 1, 'posted once')
    for _ = 1, 240 do -- no remote watch or check: the poll, else the frames without sync
        local f = w.frame()
        if f.members then
            assert(same(f, {members = 1, read_into = 12}), 'the poll of a lobby without others: ' .. budget.describe(f))
        else
            -- idle, a binding check, or the local chain check (reads only: no alive() sweep without a unit change)
            local chain = f.read_into and f.read_into >= 20 and same(f, {read_into = f.read_into})
            assert(chain or same(f, {read_into = 1}) or same(f, {read_into = 3}), budget.describe(f))
        end
    end
end)

check('its settings change: a new job with them; its Helldiver respawns: the new units recolored', function()
    local w = world(with_remote())
    w.frames(4)
    w.lobby.members[2].value = 'v=1;m=3;f=3;s=0;' -- armor matches helmet: their armor is the target now
    w.frames(124)
    local last = requests[#requests]
    assert(last.target == 'remote' and last.mode == Recolor.ARMOR_FROM_HELMET, 'their new mode')
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'their helmet no longer a target') end
    w.lobby.members[2].value = SHARED
    w.frames(124)
    local texture = w.bound(0x200)[1]
    assert(texture ~= vanilla(w), 'their helmet again')
    w.engine.units[0x200].alive = false -- a respawn: new piece units
    w.engine.unit(0x201, HELMET_LUT)
    w.space.u32(remote_unit_at(0, 0), 0x201)
    w.frames(Remote.WATCH_FRAMES + 3)
    assert(w.bound(0x201)[1] == texture, 'the new unit bound to the same texture within a few frames')
end)

check('a squadmate\'s respawn with the same look rebinds its applied result without a job (the audit, rank 11); a '
      .. 'record a transmog recomposed meanwhile gets a job', function()
    local w = world(with_remote())
    w.frames(8)
    local texture, count = w.bound(0x200)[1], #requests
    assert(texture ~= vanilla(w), 'recolored')
    w.engine.units[0x200].alive = false -- a respawn: new piece units, the same kits
    w.engine.unit(0x201, HELMET_LUT)
    w.space.u32(remote_unit_at(0, 0), 0x201)
    w.frames(Remote.WATCH_FRAMES + 1)
    assert(w.bound(0x201)[1] == texture and #requests == count and w.instance.remote.rebinds == 1,
           'the new unit bound to the same texture, no job')
    helpers.records[REMOTE_HELMET] = 'record 11111111 composed with another look'
    w.engine.units[0x201].alive = false
    w.engine.unit(0x202, HELMET_LUT)
    w.space.u32(remote_unit_at(0, 0), 0x202)
    w.frames(Remote.WATCH_FRAMES + 3)
    helpers.records[REMOTE_HELMET] = nil
    assert(#requests == count + 1 and requests[#requests].target == 'remote', 'a recomposed record: a job')
end)

check('a squadmate whose items match their cape (Helmet and Armor Match Cape) respawns in another cape: a job, not the '
      .. 'old result (user request 2026-10-09)', function()
    local w = setup({lobby = {local_id = LOCAL_ID, members = with_remote('v=1;m=4;f=3;s=0;')}})
    w.space.u32(Fake.CUSTOMIZATION + 2420 + 68, 0x72492837) -- the squadmate's cape, before the first frame
    w.frames(13)
    local function remote_requests()
        local out = {}
        for _, r in ipairs(requests) do if r.target == 'remote' then out[#out + 1] = r end end
        return out
    end
    local before = remote_requests()
    local last = before[#before]
    assert(last and last.mode == 4 and last.cape == 0x72492837, 'their settings and their cape asked for')
    assert(w.bound(0x200)[1] ~= vanilla(w), 'recolored')
    w.space.u32(Fake.CUSTOMIZATION + 2420 + 68, 0x03f9d46b) -- another cape, then a respawn
    w.engine.units[0x200].alive = false
    w.engine.unit(0x201, HELMET_LUT)
    w.space.u32(remote_unit_at(0, 0), 0x201)
    w.frames(Remote.WATCH_FRAMES + 3)
    local after = remote_requests()
    assert(#after == #before + 1 and after[#after].cape == 0x03f9d46b and w.instance.remote.rebinds == 0,
           'the new cape: a job, no rebind')
end)

check('squadmates waiting for jobs are served in turn: one whose look keeps changing cannot keep another waiting',
      function()
    local stub_recolor = {controller = function()
        return {restore = function() end, retired = {}, probes = 0, apply = function() return 0 end}
    end}
    local stub_avatar = {
        players = function()
            return {{player = 7, peer_low = 1, peer_high = 0, unit = 0x71}, {player = 8, peer_low = 2, peer_high = 0, unit = 0x72}}
        end,
        resolve_remote = function(_, _, player) return {helmet = player.unit, armor = 2, body = 0, cape = 0, units_at = 0} end,
        watch = function() return {changed = function() return false end} end,
    }
    local r = Remote.new({Avatar = stub_avatar, Recolor = stub_recolor, Sync = Sync, note = function() end,
                          records_same = function() return true end})
    r.update(1, {{peer_low = 1, peer_high = 0, text = SHARED}, {peer_low = 2, peer_high = 0, text = SHARED}})
    local first = assert(r.request())
    r.entries[first.key].dirty = true -- its look changed again before the other was served
    local second = assert(r.request())
    assert(second.key ~= first.key, 'the other one first')
    local third = assert(r.request())
    assert(third.key == first.key and r.request() == nil, 'then the first again; nothing left')
end)

check('not joined: no post and no member read, the others restored; a new lobby gets the value again', function()
    local w = world(with_remote())
    w.frames(700)
    assert(#w.lobby.posts == 1, 'posted in the first lobby')
    w.lobby.set_joined(false)
    local reads = 0
    for _ = 1, 240 do
        local f = w.frame()
        assert(not f.members and not f.post and not f.property, 'no PlayFab call while not joined')
        reads = math.max(reads, f.read_into or 0)
    end
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'restored while not joined') end
    w.lobby.set_joined(true)
    w.lobby.set_handle(0x12345678, 0x9abcdef0)
    w.frames(Sync.STEADY_FRAMES - 4)
    assert(#w.lobby.posts == 1, 'not before the new lobby is steady')
    w.frames(128)
    local post = w.lobby.posts[#w.lobby.posts]
    assert(#w.lobby.posts == 2 and post.text == SHARED and post.low == 0x12345678 and post.high == 0x9abcdef0,
           'posted to the new lobby')
    assert(w.bound(0x200)[1] ~= vanilla(w), 'recolored in the new lobby')
end)

check('a lobby that is left before the first post, then joined again: the steady wait starts over', function()
    local w = world({{id = LOCAL_ID}})
    w.frames(300) -- polled (first at frame 4), not yet posted
    w.lobby.set_joined(false)
    w.frames(240)
    w.lobby.set_joined(true) -- the same handle
    w.frames(1100 - w.instance.state.frame)
    assert(#w.lobby.posts == 0, 'not STEADY_FRAMES after the first poll: after the rejoin')
    w.frames(200)
    assert(#w.lobby.posts == 1, 'posted once steady again')
end)

check('a failed post is retried after RETRY_FRAMES, never sooner; without PlayFab\'s exports sync stays idle',
      function()
    local w = world({{id = LOCAL_ID}})
    w.lobby.post_result = -2147024891 -- E_ACCESSDENIED as PlayFab's int32
    local failed_at
    for _ = 1, Sync.STEADY_FRAMES + Sync.POLL_FRAMES + 2 do
        if w.frame().post then failed_at = w.instance.state.frame end
    end
    assert(#w.lobby.posts == 1 and logged(w, 'Sync: post failed (0x80070005); retrying later.'), 'failed once')
    w.frames(failed_at + Sync.RETRY_FRAMES - 1 - w.instance.state.frame)
    assert(#w.lobby.posts == 1, 'not before the retry delay')
    w.lobby.post_result = 0
    w.frames(2 * Sync.POLL_FRAMES)
    assert(#w.lobby.posts == 2 and w.instance.session.posted_text == SHARED, 'posted on the retry')
    local missing = world(with_remote(), {natives = function() return nil, 'PlayFab lobby exports missing' end})
    for _ = 1, 600 do
        local f = missing.frame()
        assert(not f.members and not f.post, 'no PlayFab call')
    end
    local count = 0
    for _, line in ipairs(missing.lines) do if line == 'Sync: PlayFab lobby exports missing.' then count = count + 1 end end
    assert(count == 1 and not missing.instance.remote.order[1], 'logged once, nobody recolored')
end)

check('the local member never drives a recolor without the loopback; unreadable values and strangers are skipped',
      function()
    local w = world({{id = LOCAL_ID, value = 'v=1;m=3;f=3;s=0;'}, {id = REMOTE_ID, value = 'garbage'},
                     {id = 'ABCDEF', value = SHARED}})
    local before = #requests
    w.frames(400)
    assert(not w.instance.remote.order[1], 'no entry')
    for i = before + 1, #requests do assert(requests[i].target ~= 'remote', 'no remote job') end
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'the other player untouched') end
    assert(w.bound(0x100)[1] ~= vanilla(w), 'the local recolor as before')
    -- the stranger shares readable settings but names no player here: noted once (the two-player test's question)
    local count = 0
    for _, line in ipairs(w.lines) do
        if line == 'Sync: 0000000000abcdef shares settings; no Helldiver of theirs found here yet.' then
            count = count + 1
        end
    end
    assert(count == 1, 'the stranger noted once: ' .. count)
end)

check('a failing job for another player is tried FAILURE_LIMIT times, then left until its settings change', function()
    -- their helmet makes the canned job fail from the first frame (sync is always on: the first poll is on frame 4)
    local before = #requests
    local w = setup({lobby = {local_id = LOCAL_ID, members = with_remote()}})
    w.space.u32(Fake.CUSTOMIZATION + 2416 + 68, FAIL_HELMET)
    w.frames(605)
    local tries = 0
    for i = before + 1, #requests do if requests[i].target == 'remote' then tries = tries + 1 end end
    assert(tries == Remote.FAILURE_LIMIT, tries .. ' tries')
    assert(logged(w, 'Sync: recolor of ' .. REMOTE_KEY .. ' failed (3/3): canned failure'), 'logged')
    w.space.u32(Fake.CUSTOMIZATION + 2416 + 68, REMOTE_HELMET)
    w.lobby.members[2].value = 'v=1;m=2;f=1;s=0;' -- new settings: tried again
    w.frames(124)
    assert(w.bound(0x200)[1] ~= vanilla(w), 'recolored with the new settings')
end)

check('the post crash (2026-10-07): the game\'s copy of the local key may hold a bad pointer; PlayFab gets its own '
      .. 'key; no post while the member list lacks the local member', function()
    local w = setup({lobby = {local_id = LOCAL_ID, members = {{id = REMOTE_ID, value = SHARED}, {id = LOCAL_ID}}}})
    w.space.u64(Fake.PLAYFAB_LOBBY + 0x138, 0x13fe3012e) -- the bad pointer PlayFab read in the user's dump
    w.frames(700)
    local post = w.lobby.posts[1]
    assert(#w.lobby.posts == 1 and post.user == post.array + 16, 'the local member\'s own key, from this poll\'s list')
    assert(w.bound(0x200)[1] ~= vanilla(w), 'the other player recolored all the same')
    local alone = setup({lobby = {local_id = LOCAL_ID, members = {{id = REMOTE_ID, value = SHARED}}}})
    alone.frames(1000)
    assert(#alone.lobby.posts == 0, 'no post while the member list lacks the local member')
    assert(alone.bound(0x200)[1] ~= vanilla(alone), 'the others still read and recolored')
end)

check('no lobby read before the local Helldiver exists (title screen, loading, dead); then the first post once the '
      .. 'lobby is steady', function()
    local Avatar = require('avatar')
    local w = setup({lobby = {local_id = LOCAL_ID, members = {{id = LOCAL_ID}}}})
    local players = w.space.get32(Fake.GAME + Avatar.PLAYERS) + w.space.get32(Fake.GAME + Avatar.PLAYERS + 4) * 2 ^ 32
    w.space.u64(Fake.GAME + Avatar.PLAYERS, 0) -- no player manager yet
    for _ = 1, 600 do
        local f = w.frame()
        assert(not f.members and not f.post and not f.property, 'no PlayFab call: ' .. budget.describe(f))
    end
    w.space.u64(Fake.GAME + Avatar.PLAYERS, players)
    local first, polls
    for _ = 1, 1000 do
        local f = w.frame()
        if f.members then polls = (polls or 0) + 1 first = first or w.instance.state.frame end
        if f.post then
            assert(w.instance.state.frame - first >= Sync.STEADY_FRAMES, 'posted only once the lobby was steady')
            break
        end
    end
    assert(#w.lobby.posts == 1, 'posted once the Helldiver exists and the lobby is steady')
end)

check('loopback (test build): the own value recolors the own Helldiver through the sync path; off hands it back',
      function()
    local w = world({{id = LOCAL_ID}})
    w.instance.set_loopback(true)
    w.frames(3)
    assert(requests[#requests].target == 'avatar' and requests[#requests].mode == Recolor.OFF, 'the local recolor off')
    for _, object in ipairs(w.bound(0x100)) do assert(object == vanilla(w), 'the local path restored it') end
    w.frames(Sync.STEADY_FRAMES + 2 * Sync.POLL_FRAMES)
    local entry = w.instance.remote.entries[LOCAL_KEY]
    assert(entry and requests[#requests].key == LOCAL_KEY, 'the local member is an entry')
    local texture = entry.controller.textures[HELMET_LUT]
    assert(texture and w.bound(0x100)[1] == texture.object, 'recolored by the sync path')
    w.instance.set_loopback(false)
    for _, object in ipairs(w.bound(0x100)) do assert(object == vanilla(w), 'given back at once') end
    w.frames(3)
    local own = w.instance.controller.textures[HELMET_LUT]
    assert(own and w.bound(0x100)[1] == own.object, 'the local recolor again')
    w.frames(240)
    assert(not w.instance.remote.order[1] and w.bound(0x100)[1] == own.object, 'and it stays')
end)

check('pause and stop give the others their own colors; after a resume the next poll finds them again', function()
    local w = world(with_remote())
    w.frames(4)
    w.instance.pause('test')
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'restored by the pause') end
    w.frames(10)
    assert(w.bound(0x200)[1] ~= vanilla(w), 'found again after the resume')
    w.instance.stopped('unloaded')
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'restored by the stop') end
end)

-- Recolor Squadmates (v1.5, user request 2026-10-14: "a toggle for 'Apply to entire team' ... odd being the only one
-- that's been re-colored into camo"): squadmates without the mod take this player's settings, or every squadmate does.
local MISSING, EVERYONE = 2, 3
local function without_mod() return {{id = LOCAL_ID}, {id = REMOTE_ID}} end

check('Recolor Squadmates, Squadmates Without the Mod: a squadmate who shares nothing takes your settings at the next '
      .. 'frame\'s poll; Off gives their colors back; never posted, no job of your own', function()
    local w = world(without_mod())
    w.frames(240)
    assert(not w.instance.remote.order[1], 'off: a squadmate without the mod keeps their colors')
    local before, posts, sync_text = #requests, #w.lobby.posts, w.instance.state.sync_text
    w.instance.set_option('squad', MISSING)
    assert(w.instance.state.sync_text == sync_text, 'your shared value unchanged (v1.4 squadmates still read it)')
    w.frames(4) -- the poll on the next frame, the job over two frames, its apply
    for i = before + 1, #requests do assert(requests[i].target ~= 'avatar', 'no job of your own') end
    local last = requests[#requests]
    assert(last.target == 'remote' and last.key == REMOTE_KEY and last.mode == Recolor.HELMET_FROM_ARMOR
           and last.keep_sets == true and last.keep_hoods == false and last.scheme == 0, 'your settings')
    assert(w.bound(0x200)[1] ~= vanilla(w), 'their helmet recolored')
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' recolored, 2 materials (your settings).'), 'logged as yours')
    assert(#w.lobby.posts == posts, 'nothing posted for it')
    w.instance.set_option('squad', 1)
    w.frames(2)
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'off: their colors back') end
    assert(not w.instance.remote.order[1], 'and no entry')
end)

check('Recolor Squadmates: a squadmate who shares keeps their own settings with Squadmates Without the Mod and takes '
      .. 'yours with Everyone; your option changes reach the squadmates who take yours', function()
    local w = world(with_remote('v=1;m=3;f=3;s=0;')) -- they chose Armor Matches Helmet
    w.instance.set_option('squad', MISSING)
    w.frames(8)
    assert(requests[#requests].target == 'remote' and requests[#requests].mode == Recolor.ARMOR_FROM_HELMET,
           'their own mode')
    w.instance.set_option('squad', EVERYONE)
    w.frames(6)
    local last = requests[#requests]
    assert(last.target == 'remote' and last.mode == Recolor.HELMET_FROM_ARMOR, 'yours with Everyone')
    assert(w.bound(0x200)[1] ~= vanilla(w), 'their helmet recolored with your settings')
    local count = #requests
    w.instance.set_option('match_materials', true)
    w.frames(6)
    local again
    for i = count + 1, #requests do if requests[i].target == 'remote' then again = requests[i] end end
    assert(again and again.materials == true, 'your new setting reaches them')
    count = #requests
    w.instance.set_option('mode', Recolor.OFF) -- your own recoloring off: they show their own shared settings again
    w.frames(8)
    local own
    for i = count + 1, #requests do if requests[i].target == 'remote' then own = requests[i] end end
    assert(own and own.mode == Recolor.ARMOR_FROM_HELMET, 'their own mode again')
end)

check('a squadmate without a Helldiver (dead) keeps their entry and textures; on respawn the same look is bound '
      .. 'again without a job (v1.3 dropped the entry and ran a job on every respawn)', function()
    local w = world(with_remote())
    w.frames(4)
    local texture = w.bound(0x200)[1]
    assert(texture ~= vanilla(w), 'recolored')
    local unit_at = Fake.PLAYERS + 936 + 32
    local unit = w.space.get32(unit_at)
    w.space.u32(unit_at, 0) -- dead: the player has no unit
    w.frames(240)
    local e = w.instance.remote.entries[REMOTE_KEY]
    assert(e and e.absent, 'kept, absent')
    assert(not logged(w, 'Sync: ' .. REMOTE_KEY .. ' restored.'), 'not restored')
    local count = #requests
    w.engine.units[0x200].alive = false -- the respawn: new piece units
    w.engine.unit(0x201, HELMET_LUT)
    w.space.u32(remote_unit_at(0, 0), 0x201)
    w.space.u32(unit_at, unit)
    w.frames(124)
    assert(not w.instance.remote.entries[REMOTE_KEY].absent, 'back')
    assert(w.bound(0x201)[1] == texture, 'the new units bound to the same texture')
    for i = count + 1, #requests do assert(requests[i].target ~= 'remote', 'no job: rebound') end
end)

check('a squadmate whose value fails to read keeps their entry as it is (Recolor Squadmates on: no flip to your '
      .. 'settings and back)', function()
    local w = world(with_remote('v=1;m=3;f=3;s=0;'))
    w.instance.set_option('squad', MISSING)
    w.frames(8)
    local count = #requests
    w.lobby.members[2].fail = true
    w.frames(240)
    for i = count + 1, #requests do assert(requests[i].target ~= 'remote', 'no job while the read fails') end
    assert(w.instance.remote.entries[REMOTE_KEY].settings.mode == Recolor.ARMOR_FROM_HELMET, 'their own settings kept')
end)

check('Recolor Squadmates: the calls a squadmate without the mod adds are a sharer\'s (a poll every 120 frames, one '
      .. 'read on 1 frame in 4, two every 30); none with the option Off', function()
    local w, twin = world(without_mod()), setup({})
    twin.frames(5)
    for _ = 1, 10 do w.frame() twin.frame() end
    for _ = 1, 240 do -- off: the poll alone (the lobby, its two members, no player records), no watch or check
        local extra = diff(w.frame(), twin.frame())
        if extra.members then
            -- its two lookups: cbmyc2, then cbmyc (v1.5: a player without the mod has neither)
            assert(same(extra, {members = 1, property = 2, read_into = 13}), 'off poll: ' .. budget.describe(extra))
        else
            assert(next(extra) == nil, 'off: ' .. budget.describe(extra))
        end
    end
    w.instance.set_option('squad', MISSING)
    for _ = 1, 10 do w.frame() twin.frame() end -- recolored
    local polls = 0
    for _ = 1, 600 do
        local extra = diff(w.frame(), twin.frame())
        local frame = w.instance.state.frame
        local expected = {}
        if extra.members then -- a sharer's 28 less its value (two lookups: neither key); the own value posted once
            -- the lobby is steady
            expected, polls = {members = 1, property = 2, read_into = 27, post = extra.post and 1 or nil}, polls + 1
        elseif frame % Remote.WATCH_FRAMES == 0 then
            expected = {read_into = 1}
        elseif frame % 30 == 1 then
            expected = {read_into = 2}
        end
        assert(same(extra, expected), 'frame ' .. frame .. ': ' .. budget.describe(extra) .. ', expected '
               .. budget.describe(expected))
    end
    assert(polls == 5, polls .. ' polls')
end)

print('PASS test_sync (' .. passed .. ' checks)')
