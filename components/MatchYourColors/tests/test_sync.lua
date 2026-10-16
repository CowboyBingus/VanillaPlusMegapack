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

-- Every option combination (the FLAGS bits, Recolor Weapons and Hide Cape's shared flag included) for each mode and a
-- few schemes.
local function each_options(fn)
    for mode = 1, 4 do
        for flags = 0, 63 do
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
            assert(old[k] == ((k ~= 'recolor_weapons' and k ~= 'cape_hidden') and v or false), legacy .. ': ' .. k)
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
            -- 7 for the lobby, 2 per member (key, id) and 2 for the local one's type, 1 for the other's value, 10 for
            -- the players (the map and this machine's record: 6, 2 a player; 14 before the map, 2026-10-16); the value
            -- posted once the lobby has stayed joined for STEADY_FRAMES (first poll:
            -- frame 5, as frame 4 applies the local recolor)
            expected, polls = {members = 1, property = 1, read_into = 24, post = frame == 605 and 1 or nil}, polls + 1
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
    -- other players' Helldivers are here: the players and their peer ids noted once too (the first real squad,
    -- 2026-10-15: three squadmates, none recolored; a player's peer id can be 0, game.dll 0x6054f0)
    local players = {}
    for _, line in ipairs(w.lines) do
        if line:find('Sync: 0000000000abcdef is none of the players here: ', 1, true) then players[#players + 1] = line end
    end
    assert(#players == 1 and players[1]:find("index 0 peer 00c0ffee5eed0001 unit 96 slot 1 (this machine's), "
           .. 'index 1 peer 0000000000001234 unit 97 slot 3; session: no session.', 1, true),
           'the players and the session noted once: ' .. tostring(players[1]))
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

check('a squadmate here whose peer id is 0 (game.dll sets it once, when the player is added, 0 while the connection is '
      .. 'not known; the squads of 2026-10-15/16: no squadmate recolored in the mission) takes your settings with '
      .. 'Everyone, and with Squadmates Without the Mod while nobody shares; the log names the players', function()
    local w = world(without_mod())
    w.space.u32(Fake.PLAYERS + 712 + 56, 0) -- the remote player's peer id
    w.instance.set_option('squad', EVERYONE)
    w.frames(8)
    local e = w.instance.remote.entries['player 6']
    assert(e and w.bound(0x200)[1] ~= vanilla(w), 'their Helldiver recolored, as a player no member names')
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' is none of the players here: '), 'the players logged')
    w.instance.set_option('squad', MISSING)
    w.frames(8)
    assert(w.bound(0x200)[1] ~= vanilla(w), 'nobody shares: still yours')
    w.lobby.members[2].value = SHARED -- a sharer in the lobby: the player could be theirs
    w.frames(Sync.POLL_FRAMES + 8)
    assert(not w.instance.remote.entries['player 6'], 'no entry')
    for _, object in ipairs(w.bound(0x200)) do assert(object == vanilla(w), 'their own colors') end
end)

-- Squadmates' Colors (2026-10-16, the user: "make their color scheme match the players' as well", Their Own Gear kept as
-- a distinct choice): with Your Colors the squadmates Recolor Squadmates recolors take this player's mode's source item.
local function last_remote(from)
    local found
    for i = from + 1, #requests do if requests[i].target == 'remote' and not requests[i].weapons then found = requests[i] end end
    return found
end

check('Squadmates\' Colors, Your Colors: a squadmate\'s job carries your source item (your armor with Helmet Matches '
      .. 'Armor, your helmet with Armor Matches Helmet, your cape with Match Cape; nothing with a paint scheme), follows '
      .. 'your gear, and Their Own Gear plans their own pair again', function()
    local w = world(without_mod())
    w.instance.set_option('squad', EVERYONE)
    w.frames(8)
    local count = #requests
    assert(not last_remote(0).source_kit, 'Their Own Gear (the default): their own pair')
    w.instance.set_option('squad_colors', 2)
    w.frames(8)
    local r = last_remote(count)
    assert(r and r.source_kit == 0x0ade6719 and r.cape ~= 0x72492837, 'Helmet Matches Armor: your armor')
    count = #requests
    w.instance.set_option('mode', Recolor.ARMOR_FROM_HELMET)
    w.frames(8)
    r = last_remote(count)
    assert(r and r.source_kit == 0xa5574ac2, 'Armor Matches Helmet: your helmet')
    count = #requests
    w.instance.set_option('mode', Recolor.CAPE_SOURCE)
    w.frames(8)
    r = last_remote(count)
    assert(r and not r.source_kit and r.source_cape == 0x72492837 and r.cape == 0x72492837,
           'Helmet and Armor Match Cape: your cape as their source')
    count = #requests
    w.instance.set_option('mode', Recolor.HELMET_FROM_ARMOR)
    w.frames(8)
    w.space.u32(Fake.CUSTOMIZATION + 2424, 0x4f7fb2bd) -- you put on another armor
    w.frames(Sync.POLL_FRAMES + 20)
    r = last_remote(count)
    assert(r and r.source_kit == 0x4f7fb2bd, 'your new armor reaches them: ' .. string.format('%x', r and r.source_kit or 0))
    count = #requests
    w.instance.set_option('scheme', 3)
    w.frames(8)
    r = last_remote(count)
    assert(r and r.scheme == 3 and not r.source_kit and not r.source_cape, 'a paint scheme: the scheme alone')
    w.instance.set_option('scheme', 0)
    w.frames(8)
    count = #requests
    w.instance.set_option('squad_colors', 1)
    w.frames(8)
    r = last_remote(count)
    assert(r and not r.source_kit and not r.source_cape, 'Their Own Gear again: their own pair')
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
    -- with Everyone too: their player stays their entry's, never a second entry as a player no member names
    w.instance.set_option('squad', EVERYONE)
    w.frames(Sync.POLL_FRAMES + 8)
    assert(not w.instance.remote.entries['player 6'], 'no second entry for their Helldiver')
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
        if extra.members then -- a sharer's 24 less its value (two lookups: neither key); the own value posted once
            -- the lobby is steady
            expected, polls = {members = 1, property = 2, read_into = 23, post = extra.post and 1 or nil}, polls + 1
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

-- The squad cards (src/lineup.lua; user 2026-10-15, joining a mission in progress: "The squad preview window is
-- broken. None of the squad matching appears there."). The Armory's slot (pm + 948: 1 here) held a squadmate's card,
-- which v1.5 took for this player's preview and recolored with this player's options; this player's own card (session
-- slot 2) and every other card kept their colors. Agreed outcome: each card shows its player's settings.
local ARMOR_LUT = 'a007a73e4082430e'
local LOCAL_PEER, REMOTE_PEER = {0x5eed0001, 0x00c0ffee}, {0x1234, 0}
local LOCAL_KITS = {helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0, cape = 0x72492837}
local REMOTE_KITS = {helmet = REMOTE_HELMET, armor = REMOTE_ARMOR, body = 0, cape = 0x72492837}
-- The loadout screen's world: the session lists the squadmate in card_slot and this player in own_slot; card units
-- 0x400 (helmet) and 0x401 (armor) for the squadmate's card, 0x410 for this player's, 0x420 for a stranger's.
local function squad_screen(members, card_slot, own_slot)
    local w = setup({ui = true, lobby = {local_id = LOCAL_ID, members = members}})
    Fake.session(w.space, LOCAL_PEER, {{REMOTE_PEER[1], REMOTE_PEER[2], card_slot},
                                       {LOCAL_PEER[1], LOCAL_PEER[2], own_slot}})
    Fake.desired(w.space, 0, LOCAL_KITS)
    Fake.desired(w.space, 1, REMOTE_KITS)
    w.engine.unit(0x400, HELMET_LUT) w.engine.unit(0x401, ARMOR_LUT)
    w.engine.unit(0x410, HELMET_LUT) w.engine.unit(0x420, HELMET_LUT)
    w.frames(5)
    return w
end
local function show_card(w, slot, kits, unit)
    Fake.show_ui(w.space, slot, kits, {[{0, 0}] = unit, [{0, 2}] = unit == 0x400 and 0x401 or nil})
end
local function card_requests(w, from)
    local out = {}
    for i = from + 1, #requests do
        local r = requests[i]
        if r.target == 'card' or r.target == 'ui' then out[#out + 1] = r end
    end
    return out
end

check('the squad cards (reported 2026-10-15): the Armory\'s slot held a squadmate\'s card; it takes their settings '
      .. '(yours with Everyone), your own card in its session slot takes your options, the log names the owners; Off '
      .. 'gives their card its colors back, a closed screen drops the cards', function()
    local w = squad_screen(without_mod(), 1, 2)
    w.instance.set_option('squad', EVERYONE)
    local count = #requests
    show_card(w, 1, REMOTE_KITS, 0x400)
    show_card(w, 2, LOCAL_KITS, 0x410)
    w.frames(20)
    local card, own, wrong
    for _, r in ipairs(card_requests(w, count)) do
        if r.target == 'card' then card = r end
        if r.target == 'ui' and r.helmet == LOCAL_KITS.helmet then own = r end
        if r.target == 'ui' and r.helmet == REMOTE_HELMET then wrong = r end
    end
    assert(card and card.key == REMOTE_KEY and card.slot == 1 and card.helmet == REMOTE_HELMET
           and card.mode == Recolor.HELMET_FROM_ARMOR, 'their card: a job of its own, with your settings')
    assert(own, 'your card: your preview\'s job, for your kits')
    assert(not wrong, 'their card never takes your preview\'s job (v1.5 did)')
    assert(w.bound(0x400)[1] ~= vanilla(w), 'their card recolored')
    assert(w.bound(0x410)[1] ~= vanilla(w), 'your card recolored')
    assert(w.instance.state.ui.where.slot == 2, 'your preview watched in your session slot')
    assert(logged(w, 'Squad cards: slot 1 ' .. REMOTE_KEY .. ' (your settings), slot 2 you.'), 'owners logged')
    assert(logged(w, 'Squad card ' .. REMOTE_KEY .. ' (slot 1): '), 'the card logged')
    w.instance.set_option('squad', 1) -- they share nothing: their card in its own colors after the next poll
    w.frames(4)
    for _, object in ipairs(w.bound(0x400)) do assert(object == vanilla(w), 'off: their card in its own colors') end
    assert(w.bound(0x410)[1] ~= vanilla(w), 'your card still recolored')
    w.instance.set_option('squad', EVERYONE)
    w.frames(12)
    assert(w.bound(0x400)[1] ~= vanilla(w), 'on again')
    Fake.show_ui(w.space, 1, nil)
    Fake.show_ui(w.space, 2, nil)
    w.frames(4)
    assert(not next(w.instance.lineup.cards), 'the cards dropped')
    for _, object in ipairs(w.bound(0x400)) do assert(object == vanilla(w), 'their card given back') end
end)

check('the squad cards (reported again 2026-10-16, joining a mission in progress: "Still doesn\'t work."): the session '
      .. 'still lists only you, in slot 0, where a squadmate\'s card is; your card is found by your own kits, the other '
      .. 'card is a squadmate\'s and takes your settings with Everyone, or with Squadmates Without the Mod while nobody '
      .. 'else shares any', function()
    local w = squad_screen(without_mod(), 1, 2)
    Fake.session(w.space, LOCAL_PEER, {{LOCAL_PEER[1], LOCAL_PEER[2], 0}}) -- the session before the join settles
    w.instance.set_option('squad', EVERYONE)
    w.frames(4)
    local count = #requests
    show_card(w, 0, REMOTE_KITS, 0x400)
    show_card(w, 2, LOCAL_KITS, 0x410)
    w.frames(20)
    local card, own
    for _, r in ipairs(card_requests(w, count)) do
        assert(r.target ~= 'ui' or r.helmet ~= REMOTE_HELMET, 'their card never takes your preview\'s job')
        if r.target == 'card' then card = r end
        if r.target == 'ui' and r.helmet == LOCAL_KITS.helmet then own = r end
    end
    assert(own and w.instance.state.ui.where.slot == 2, 'your card: your preview, in slot 2')
    assert(card and card.slot == 0 and card.key == 'squad' and card.mode == Recolor.HELMET_FROM_ARMOR,
           'their card: a squadmate\'s, with your settings')
    assert(w.bound(0x400)[1] ~= vanilla(w) and w.bound(0x410)[1] ~= vanilla(w), 'both cards recolored')
    assert(logged(w, 'Squad cards: slot 0 a squadmate (your settings), slot 2 you.'), 'owners logged')
    assert(logged(w, 'Squad card of a squadmate (slot 0): '), 'the card logged')
    w.instance.set_option('squad', MISSING) -- nobody else shares settings: still yours
    w.frames(12)
    assert(w.bound(0x400)[1] ~= vanilla(w), 'Squadmates Without the Mod, nobody sharing: recolored')
    w.lobby.members[2].value = SHARED -- someone shares: the unknown card could be theirs, so it keeps its colors
    w.frames(Sync.POLL_FRAMES + 8)
    for _, object in ipairs(w.bound(0x400)) do assert(object == vanilla(w), 'a sharer in the squad: its colors') end
end)

check('Squadmates\' Colors, Your Colors: a squadmate\'s card takes your source item too', function()
    local w = squad_screen(without_mod(), 1, 2)
    w.instance.set_option('squad', EVERYONE)
    w.instance.set_option('squad_colors', 2)
    w.frames(4)
    local count = #requests
    show_card(w, 1, REMOTE_KITS, 0x400)
    show_card(w, 2, LOCAL_KITS, 0x410)
    w.frames(20)
    local card
    for _, req in ipairs(card_requests(w, count)) do if req.target == 'card' then card = req end end
    assert(card and card.source_kit == LOCAL_KITS.armor, 'their card planned against your armor')
end)

check('a squad card shown before the game fills in its kits (0: the squad of 2026-10-16 logged three failed jobs per card, '
      .. '"kit 00000000 not in the catalogue", and the cards were recolored only as the mission loaded) waits for them: '
      .. 'one job, for its kits, no failure', function()
    local w = squad_screen(without_mod(), 1, 2)
    Fake.session(w.space, LOCAL_PEER, {{LOCAL_PEER[1], LOCAL_PEER[2], 0}})
    w.instance.set_option('squad', EVERYONE)
    w.frames(4)
    local count, lines = #requests, #w.lines
    show_card(w, 2, LOCAL_KITS, 0x410)
    show_card(w, 0, {helmet = 0, armor = 0, body = 0, cape = 0}, 0x400) -- shown, its kits not set yet
    w.frames(12)
    show_card(w, 0, REMOTE_KITS, 0x400)
    w.frames(12)
    local cards = 0
    for _, r in ipairs(card_requests(w, count)) do
        if r.target == 'card' then
            cards = cards + 1
            assert(r.helmet == REMOTE_HELMET, 'planned for its kits only')
        end
    end
    assert(cards == 1 and w.bound(0x400)[1] ~= vanilla(w), 'one job, recolored: ' .. cards)
    for i = lines + 1, #w.lines do assert(not w.lines[i]:find('recolor failed', 1, true), w.lines[i]) end
end)

check('a squad card of a squadmate who shares takes their own settings with Recolor Squadmates off; another shown '
      .. 'slot listed for nobody is a squadmate\'s card whose player is not known: with the option off it keeps its '
      .. 'colors', function()
    local w = squad_screen(with_remote('v=1;m=3;f=3;s=0;'), 3, 2) -- they chose Armor Matches Helmet
    local count = #requests
    show_card(w, 3, REMOTE_KITS, 0x400)
    show_card(w, 2, LOCAL_KITS, 0x410)
    show_card(w, 0, {helmet = 0x33333333, armor = 0x44444444, body = 0}, 0x420)
    w.frames(20)
    local card
    for _, r in ipairs(card_requests(w, count)) do
        if r.target == 'card' then card = r end
        assert(r.helmet ~= 0x33333333, 'nothing planned for the stranger\'s slot')
    end
    assert(card and card.slot == 3 and card.mode == Recolor.ARMOR_FROM_HELMET, 'their own mode')
    assert(w.bound(0x401)[1] ~= w.engine.vanilla[ARMOR_LUT], 'their card\'s armor recolored')
    for _, object in ipairs(w.bound(0x420)) do assert(object == vanilla(w), 'the stranger\'s slot as it is') end
    assert(logged(w, 'Squad cards: slot 0 a squadmate (keeps its colors), slot 2 you, slot 3 ' .. REMOTE_KEY
                     .. ' (shared settings).'), 'owners logged')
    -- their value fails to read: the card keeps their settings (no flip to yours and back)
    local before = #requests
    w.instance.set_option('squad', EVERYONE)
    w.frames(12)
    local yours
    for _, r in ipairs(card_requests(w, before)) do if r.target == 'card' then yours = r end end
    assert(yours and yours.mode == Recolor.HELMET_FROM_ARMOR, 'Everyone: their card in yours')
    w.instance.set_option('squad', 1)
    w.frames(12)
    local count = #requests
    w.lobby.members[2].fail = true
    w.frames(240)
    for _, r in ipairs(card_requests(w, count)) do assert(r.target ~= 'card', 'no card job while the read fails') end
    assert(w.instance.lineup.cards[3].settings.mode == Recolor.ARMOR_FROM_HELMET, 'their own settings kept')
end)

check('a squadmate\'s card shown alone in the Armory\'s slot (your own card not spawned yet) is theirs: your preview '
      .. 'leaves it to its card', function()
    local w = squad_screen(without_mod(), 1, 2)
    w.instance.set_option('squad', EVERYONE)
    local count = #requests
    show_card(w, 1, REMOTE_KITS, 0x400)
    w.frames(12)
    local card
    for _, r in ipairs(card_requests(w, count)) do
        assert(r.target ~= 'ui' or r.helmet ~= REMOTE_HELMET, 'no preview job for their card')
        if r.target == 'card' then card = r end
    end
    assert(card and card.slot == 1, 'their card\'s job')
    assert(not w.instance.state.ui.shown, 'your preview not shown')
end)

check('a squad card\'s new units with the same kits and settings are bound to its plan without a job; a card that '
      .. 'changes while its job runs gets the plan of what it shows, not the one the job made', function()
    local w = squad_screen(without_mod(), 1, 2)
    w.instance.set_option('squad', EVERYONE)
    show_card(w, 1, REMOTE_KITS, 0x400)
    w.frames(12)
    local texture, count = w.bound(0x400)[1], #requests
    assert(texture ~= vanilla(w), 'recolored')
    w.engine.unit(0x402, HELMET_LUT)
    w.engine.units[0x400].alive, w.engine.units[0x401].alive = false, false
    Fake.show_ui(w.space, 1, REMOTE_KITS, {[{0, 0}] = 0x402}) -- the card spawned again (its old units gone)
    w.frames(4)
    assert(w.bound(0x402)[1] == texture, 'the new unit bound to the same plan')
    for _, r in ipairs(card_requests(w, count)) do assert(r.target ~= 'card', 'no job: rebound') end
    -- the game puts the original texture back: the next binding check finds it and the card is recolored again
    for _, m in ipairs(w.engine.units[0x402].materials) do w.space.u64(w.engine.entry(m.material) + 8, vanilla(w)) end
    w.frames(40)
    assert(w.bound(0x402)[1] ~= vanilla(w), 'recolored again after a binding check')
    -- another outfit while its job runs: the result is not applied to what it no longer shows
    local other = {helmet = 0x0b0b0b0b, armor = REMOTE_ARMOR, body = 0, cape = 0x72492837}
    Fake.desired(w.space, 1, other)
    w.engine.unit(0x403, HELMET_LUT)
    Fake.show_ui(w.space, 1, other, {[{0, 0}] = 0x403})
    while not (w.instance.state.request and w.instance.state.request.target == 'card') do w.frame() end
    local third = {helmet = 0x0c0c0c0c, armor = REMOTE_ARMOR, body = 0, cape = 0x72492837}
    Fake.desired(w.space, 1, third)
    w.engine.unit(0x404, HELMET_LUT)
    Fake.show_ui(w.space, 1, third, {[{0, 0}] = 0x404})
    local lines = #w.lines
    w.frames(12)
    local applied = 0
    for i = lines + 1, #w.lines do
        if w.lines[i]:find('Squad card ' .. REMOTE_KEY .. ' (slot 1): ', 1, true) then applied = applied + 1 end
    end
    assert(applied == 1 and requests[#requests].helmet == third.helmet, 'one apply, for the outfit shown: ' .. applied)
end)

check('a slot the session gives a squadmate but showing other kits than theirs, in the Armory\'s slot, is the '
      .. 'player\'s own preview (the Armory there)', function()
    local w = squad_screen(without_mod(), 1, 2)
    w.instance.set_option('squad', EVERYONE)
    local count = #requests
    local armory = {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0, cape = 0x72492837}
    show_card(w, 1, armory, 0x410)
    w.frames(12)
    local own
    for _, r in ipairs(card_requests(w, count)) do
        assert(r.target ~= 'card', 'no card job')
        if r.target == 'ui' and r.helmet == armory.helmet then own = r end
    end
    assert(own and w.instance.state.ui.where.slot == 1, 'your preview, in the Armory\'s slot')
end)

check('the squad cards\' calls: the frame the cards appear reads the owners (the session, the squadmate\'s player and '
      .. 'desired kits: 9 reads more than the own card alone); settled, every frame makes the own card\'s calls but the '
      .. 'binding checks, which read one probe of the card (2 reads)', function()
    local function frames(cards)
        local w = squad_screen(without_mod(), 1, 2)
        w.instance.set_option('squad', EVERYONE)
        w.frames(200)
        while w.instance.state.frame % 4 ~= 3 do w.frame() end -- the next frame is a UI gate frame
        if cards then show_card(w, 1, REMOTE_KITS, 0x400) end
        show_card(w, 2, LOCAL_KITS, 0x410)
        local first = w.frame()
        w.frames(60)
        local kinds, probes = {}, 0
        for _ = 1, 600 do
            local f = w.frame()
            if cards and (f.read_into == 8 or f.read_into == 9) then
                f.read_into, probes = f.read_into - 2, probes + 1
            end
            local text = budget.describe(f)
            kinds[text] = (kinds[text] or 0) + 1
        end
        return first, kinds, probes
    end
    local own_first, own = frames(false)
    local first, all, probes = frames(true)
    assert(probes == 20, 'the card probed on every binding check: ' .. probes)
    assert(first.read_into == own_first.read_into + 9, 'the owners: ' .. budget.describe(first) .. ' against '
           .. budget.describe(own_first))
    for text, n in pairs(all) do assert(own[text] == n, text .. ': ' .. n .. ' frames, ' .. tostring(own[text])) end
    for text, n in pairs(own) do assert(all[text] == n, text .. ': ' .. n .. ' frames alone') end
    assert(own['read_into=6'] == 10 and own['read_into=7'] == 10, 'the binding checks of 600 frames')
end)

check('loopback (test build): the own preview goes through the squad-card path with the own shared value', function()
    local w = setup({ui = true, lobby = {local_id = LOCAL_ID, members = {{id = LOCAL_ID}}}})
    w.engine.unit(0x410, HELMET_LUT)
    w.frames(5)
    w.instance.set_loopback(true)
    w.frames(Sync.STEADY_FRAMES + 2 * Sync.POLL_FRAMES)
    local count = #requests
    show_card(w, 1, LOCAL_KITS, 0x410)
    w.frames(16)
    local card
    for _, r in ipairs(card_requests(w, count)) do
        assert(r.target ~= 'ui' or r.mode == Recolor.OFF, 'no preview job of its own')
        if r.target == 'card' then card = r end
    end
    assert(card and card.key == LOCAL_KEY and card.slot == 1, 'the card path, keyed by the local member')
    assert(w.bound(0x410)[1] ~= vanilla(w), 'recolored')
    -- loopback off: the preview's own path recolors it again (live 2026-10-15: it stayed in its own colors, the
    -- preview's path hidden while the card had the slot and nothing on screen changing after)
    count = #requests
    w.instance.set_loopback(false)
    w.frames(Sync.POLL_FRAMES + 12)
    local own
    for _, r in ipairs(card_requests(w, count)) do if r.target == 'ui' and r.mode ~= Recolor.OFF then own = r end end
    assert(own and not next(w.instance.lineup.cards), 'the preview\'s own job, no card')
    assert(w.bound(0x410)[1] ~= vanilla(w) and #w.instance.ui_controller.bindings > 0, 'recolored by the preview')
end)

-- Squadmates' weapons in a squad of three (Recolor Weapons, src/loadout.lua follow). A user's squad of four
-- (2026-10-16, a mission with every squadmate recolored) logged five 'Sync: <peer> weapons recolored, 0 materials.'
-- lines on three players: the game keeps inventory rows packed (tests/fake_game.lua Fake.weapons remove, as its
-- 0x9b2810 -> 0x9b15d0), so a squadmate's death moved another player's row into theirs and v1.5, reading the row it
-- found first, planned that player's weapons (already recolored: 0 bindings), never found its own player's new row
-- after a respawn, and let the moved player's recolor plan whatever came into its old row (a respawned squadmate's
-- weapons, with its own settings). Agreed outcome: each squadmate's weapons recolored with their own settings
-- through deaths, respawns and moved rows; no job plans another player's weapons; no '0 materials' line.
local THIRD_ID, THIRD_KEY = '5678', '0000000000005678'
local CHECK_FRAMES = require('addon').CHECK_FRAMES
local RIFLE, PISTOL, CANNON = '1a2b3c4d00000001', '1a2b3c4d00000002', '1a2b3c4d00000003'
local RIFLE_LUT, PISTOL_LUT, CANNON_LUT = '5e6f708100000001', '5e6f708100000002', '5e6f708100000003'
helpers.vanilla[RIFLE_LUT], helpers.vanilla[PISTOL_LUT], helpers.vanilla[CANNON_LUT] = 0x193000000, 0x193001000,
    0x193002000
helpers.weapon_luts[RIFLE], helpers.weapon_luts[PISTOL], helpers.weapon_luts[CANNON] = {RIFLE_LUT}, {PISTOL_LUT},
    {CANNON_LUT}
local function gun(id, name, unit) return {id = id, name = name, unit = unit, units = {}, attachments = {}} end
-- Whether unit's material holds one of controller c's textures.
local function bound_by(w, c, unit)
    local object = w.bound(unit)[1]
    for _, texture in pairs(c.textures) do if texture.object == object then return true end end
    return false
end
local function weapon_requests(from)
    local n = 0
    for i = from + 1, #requests do if requests[i].target == 'remote' and requests[i].weapons then n = n + 1 end end
    return n
end
-- The squad: this player, the squadmate (peer 0x1234: player 6, avatar 0xe6, inventory row 1, a rifle) sharing Armor
-- Matches Helmet and a third mod user (peer 0x5678: player 7, avatar 0xe7, row 2, a pistol) sharing Helmet Matches
-- Armor, both with Recolor Weapons (their own plans and textures); frames run until both weapons are recolored.
local function squad_of_three()
    local w = setup({weapons = true, lobby = {local_id = LOCAL_ID, members = {{id = LOCAL_ID},
                     {id = REMOTE_ID, value = 'v=1;m=3;f=19;s=0;'}, {id = THIRD_ID, value = 'v=1;m=2;f=19;s=0;'}}}})
    local record = Fake.player(w.space, {entity = 7, index = 2, peer = 0x5678, record = 2, helmet = 0x33333333,
        armor = 0x44444444, helldiver = {unit = 0x98, entity = 196, avatar = 0xe7, index = 2, units = {[{0, 0}] = 0x300}}})
    w.engine.unit(0x300, HELMET_LUT)
    assert(w.weapons.add(0xe7, record) == 2, 'the third player\'s row last')
    w.engine.unit(0x600, RIFLE_LUT) w.engine.unit(0x610, PISTOL_LUT)
    w.weapons.set(1, gun(0x321, RIFLE, 0x600), 1) w.weapons.hold(1, 1)
    w.weapons.set(1, gun(0x331, PISTOL, 0x610), 2) w.weapons.hold(1, 2)
    local remote = w.instance.remote
    for _ = 1, 60 do
        w.frames(10)
        local a, b = remote.entries[REMOTE_KEY], remote.entries[THIRD_KEY]
        if a and b and a.loadout and b.loadout and a.loadout.sig and b.loadout.sig then break end
    end
    return w, remote.entries[REMOTE_KEY], remote.entries[THIRD_KEY]
end
local function zero_line(w, from)
    for i = from + 1, #w.lines do if w.lines[i]:find('weapons recolored, 0 materials', 1, true) then return w.lines[i] end end
    return nil
end

check('squadmates\' weapons through a death, a respawn and rows the game moved: each recolored with their own '
      .. 'settings, no job for another player\'s weapons, no "0 materials" line (user squad 2026-10-16)', function()
    local w, mate, third = squad_of_three()
    assert(mate and third and mate.loadout.sig and third.loadout.sig, 'both squadmates\' weapons planned')
    assert(bound_by(w, mate.loadout.controller, 0x600) and bound_by(w, third.loadout.controller, 0x610),
           'each weapon recolored by its own player\'s recolor')
    -- the squadmate dies: no Helldiver; the game removes their avatar's row, the third's moves into row 1 and leaves
    -- its old bytes and entity in row 2
    local before, lines = #requests, #w.lines
    w.space.u32(Fake.PLAYERS + 936 + 32, 0)
    w.engine.units[0x200].alive, w.engine.units[0x600].alive = false, false
    w.weapons.remove(0xe6)
    w.frames(Sync.POLL_FRAMES + 4 * CHECK_FRAMES)
    assert(weapon_requests(before) == 0, 'no weapons job: ' .. weapon_requests(before))
    assert(third.loadout.where and third.loadout.where.index == 1 and third.loadout.moves == 1,
           'the third\'s row followed to row 1')
    assert(bound_by(w, third.loadout.controller, 0x610), 'the third\'s pistol still theirs')
    assert(logged(w, 'Sync: ' .. THIRD_KEY .. ' weapons: the game moved their row (2 -> 1); found again.'), 'noted')
    -- the squadmate respawns: a new avatar (0xe9) whose row is added last (row 2), the same rifle as a new entity
    local record = Fake.respawn(w.space, 1, {unit = 0x99, entity = 197, avatar = 0xe9, index = 1,
                                             units = {[{0, 0}] = 0x201}})
    w.engine.unit(0x201, HELMET_LUT) w.engine.unit(0x620, RIFLE_LUT)
    local row = w.weapons.add(0xe9, record)
    w.weapons.set(1, gun(0x322, RIFLE, 0x620), row) w.weapons.hold(1, row)
    w.frames(Sync.POLL_FRAMES + 4 * CHECK_FRAMES)
    assert(mate.loadout.where and mate.loadout.where.avatar == 0xe9 and mate.loadout.where.index == 2,
           'the squadmate\'s new row')
    assert(bound_by(w, mate.loadout.controller, 0x620), 'their new rifle recolored by their own recolor')
    assert(not bound_by(w, third.loadout.controller, 0x620), 'not by the third\'s')
    assert(bound_by(w, third.loadout.controller, 0x610), 'the third\'s pistol still theirs')
    assert(weapon_requests(before) == 0, 'the same weapons: bound without a job')
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' new Helldiver: their weapons\' row found (2).'), 'noted')
    -- the third picks up a support weapon: in their moved row, planned and recolored with their settings alone
    w.engine.unit(0x630, CANNON_LUT)
    w.weapons.set(3, gun(0x341, CANNON, 0x630), w.weapons.index(0xe7))
    w.frames(120)
    local last
    for i = before + 1, #requests do if requests[i].weapons then last = requests[i] end end
    assert(weapon_requests(before) == 1 and last.key == THIRD_KEY and last.mode == Recolor.HELMET_FROM_ARMOR,
           'one job, the third\'s')
    assert(bound_by(w, third.loadout.controller, 0x630), 'their support weapon recolored by their own recolor')
    assert(bound_by(w, mate.loadout.controller, 0x620), 'the squadmate\'s rifle untouched')
    assert(not zero_line(w, lines), 'no "0 materials" line: ' .. tostring(zero_line(w, lines)))
    -- the squad gone: each squadmate's weapons summed up (a squad test reads these)
    w.instance.remote.clear(w.instance.state.frame)
    assert(logged(w, 'Sync: ' .. THIRD_KEY .. ' weapons: 2 jobs, ') and logged(w, 'their row moved 1 times, found for a '
           .. 'new Helldiver 0 times.'), 'the third\'s summary')
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' weapons: 1 jobs, '), 'the squadmate\'s summary')
    assert(logged(w, 'found for a new Helldiver 1 times.'), 'their respawn counted')
end)

-- The calls a squadmate's recolored weapons add, idle (against a twin whose squadmate shares the same settings without
-- Recolor Weapons): on their watch turn (1 frame in Remote.WATCH_FRAMES) the weapon in hand's binding and their row;
-- on their binding check (1 frame in CHECK_FRAMES) one probe of their weapons' textures (2 reads) and their row still
-- theirs (2 reads: Weapons.owned, as the game moves rows; v1.5 had the probe alone); nothing on other frames.
check('a squadmate\'s recolored weapons, idle: 2 reads on their watch turn, 4 on their binding check (2 of them: their '
      .. 'row still theirs), none on other frames', function()
    local function squad(value)
        local w = setup({weapons = true, lobby = {local_id = LOCAL_ID, members = {{id = LOCAL_ID},
                         {id = REMOTE_ID, value = value}}}})
        w.engine.unit(0x600, RIFLE_LUT)
        w.weapons.set(1, gun(0x321, RIFLE, 0x600), 1) w.weapons.hold(1, 1)
        w.frames(Sync.POLL_FRAMES * 3)
        return w
    end
    local w, twin = squad('v=1;m=3;f=19;s=0;'), squad('v=1;m=3;f=3;s=0;')
    local e = w.instance.remote.entries[REMOTE_KEY]
    assert(e.loadout and e.loadout.entry and e.loadout.where.owner, 'their weapon in hand watched, their row checked')
    for _ = 1, 4 * CHECK_FRAMES do
        local frame = w.instance.state.frame + 1
        local extra = diff(w.frame(), twin.frame())
        local expected = frame % Remote.WATCH_FRAMES == 0 and {read_into = 2}
            or frame % CHECK_FRAMES == 1 and {read_into = 4} or {}
        assert(helpers.same(extra, expected), 'frame ' .. frame .. ': ' .. budget.describe(extra) .. ', expected '
               .. budget.describe(expected))
    end
    -- an inventory that reads differently (another game build: here a row count of 0): the row found again where it
    -- was stops the check for it, noted; not located again on later checks, no job, the weapon still theirs
    local before = #requests
    w.space.u32(Fake.INVENTORY + 20, 0)
    w.frames(6 * CHECK_FRAMES)
    assert(e.loadout.moves == 1 and not e.loadout.where.owner, 'checked once, then no more: ' .. e.loadout.moves)
    assert(logged(w, 'Sync: ' .. REMOTE_KEY .. ' weapons: their row read as moved but was not'), 'noted')
    assert(weapon_requests(before) == 0 and bound_by(w, e.loadout.controller, 0x600), 'no job, still theirs')
end)

-- Hide Cape (2026-10-16, the user: "a toggle for users to hide their capes", squadmates with the mod see it hidden too,
-- "include the option to hide everyone's cape as well"; KB match-your-colors-hide-cape). Agreed outcomes: Your Cape
-- hides this player's cape on the ship and in missions (a respawn's new cape too) and shares flag 32; squadmates whose
-- value carries it have theirs hidden here whatever this player's choice; Everyone's Capes hides every squadmate's;
-- Off shows what this player hid; no recolor job for any of it; a cape the game shows again is hidden again.
local HIDE_OFF, HIDE_YOURS, HIDE_EVERYONE = 1, 2, 3
local Addon, Cloak = require('addon'), require('cloak')
local LOCAL_CAPE = 0x106 -- tests/test_addon.lua setup: the local cape unit (slot 1)
local function hide(w, value)
    w.instance.set_option('hide_cape', value)
end
local function visibility_calls(w, unit)
    local n = 0
    for _, c in ipairs(w.engine.visibility) do if c.unit == unit then n = n + 1 end end
    return n
end
-- The squadmate's cape unit (their slot 1), as the game makes it.
local function remote_cape(w, unit)
    w.engine.unit(unit, HELMET_LUT)
    w.space.u32(remote_unit_at(0, 1), unit)
end

check('Hide Cape, Your Cape: this player\'s cape hidden at once (one call), a respawn\'s new cape too, flag 32 shared, '
      .. 'a cape the game showed again hidden again, Off shows it; no recolor job', function()
    local w = world(with_remote())
    w.frames(Sync.POLL_FRAMES * 2) -- the squadmate recolored (their own job) first
    local before = #requests
    assert(not w.engine.hidden(LOCAL_CAPE), 'shown by default')
    hide(w, HIDE_YOURS)
    assert(w.engine.hidden(LOCAL_CAPE) and visibility_calls(w, LOCAL_CAPE) == 1, 'hidden at once, one call')
    assert(logged(w, 'Hide Cape: your cape hidden (unit 106).'), 'noted')
    local shared = assert(Sync.decode(w.instance.state.sync_text))
    assert(shared.cape_hidden and shared.mode == 2 and shared.keep_sets, 'flag 32 with the other options')
    w.frames(Sync.POLL_FRAMES)
    assert(visibility_calls(w, LOCAL_CAPE) == 1, 'no call while nothing changes')
    w.engine.unit(0x108, HELMET_LUT) -- another unit changes (a new helmet unit), the cape the same: no new call
    w.space.u32(Fake.local_unit_at(0, 0), 0x108)
    w.frames(3)
    assert(visibility_calls(w, LOCAL_CAPE) == 1, 'the same cape: no new call')
    -- a respawn: new units, a new cape unit
    w.engine.unit(0x107, HELMET_LUT)
    w.space.u32(Fake.local_unit_at(0, 1), 0x107)
    w.frames(3)
    assert(w.engine.hidden(0x107) and visibility_calls(w, 0x107) == 1, 'the new cape hidden, once')
    -- a mission start: new units the game hides at once (the hellpod; live 2026-10-16) and shows again at the pod's exit,
    -- the cape too: hidden again the next frame, however long the drop lasts
    w.engine.unit(0x109, HELMET_LUT) w.engine.unit(0x10a, HELMET_LUT)
    local function mask_of(unit) return 0x180000000 + unit * 16 + Fake.MESH_VISIBILITY end
    w.space.byte(mask_of(0x109), 0)
    w.space.u32(Fake.local_unit_at(0, 0), 0x109) w.space.u32(Fake.local_unit_at(0, 1), 0x10a)
    w.frames(3)
    assert(w.engine.hidden(0x10a), 'the new cape hidden')
    w.frames(4 * Cloak.GRACE_FRAMES)
    assert(w.instance.cloak.young_until > w.instance.state.frame, 'young while the game hides the Helldiver')
    w.space.byte(mask_of(0x109), 0xFF) w.space.byte(mask_of(0x10a), 0xFF) -- the pod's exit
    local f = w.frame()
    assert(w.engine.hidden(0x10a) and f.visibility == 1 and w.instance.cloak.reshown == 1, 'hidden again the next frame')
    assert(w.instance.cloak.young_until == 0, 'no longer young')
    local since
    for _, line in ipairs(w.lines) do
        since = since or tonumber(line:match('^Hide Cape: the hellpod opened and showed your cape (%d+) frames after it '
                                             .. 'was hidden; hidden again the next frame%.$'))
    end
    assert(since and since > 4 * Cloak.GRACE_FRAMES, 'noted with the frames since it was hidden: ' .. tostring(since))
    -- shown again later (not by a pod): hidden again by the binding check (within CHECK_FRAMES frames)
    w.space.byte(mask_of(0x10a), 0xFF)
    w.frame()
    assert(not w.engine.hidden(0x10a), 'not read every frame once it is not young')
    w.frames(CHECK_FRAMES + 1)
    assert(w.engine.hidden(0x10a) and w.instance.cloak.reshown == 2, 'hidden again by the binding check')
    assert(logged(w, 'Hide Cape: the game showed your cape again '), 'noted as the game, not the hellpod')
    hide(w, HIDE_OFF)
    assert(not w.engine.hidden(0x10a) and logged(w, 'Hide Cape: your cape shown again.'), 'Off: shown')
    assert(not Sync.decode(w.instance.state.sync_text).cape_hidden, 'the flag no longer shared')
    w.frames(5)
    assert(#requests == before, 'no recolor job for any of it')
end)

check('Hide Cape while the Helldiver is briefly not found (its entity not an avatar for a moment, as on the ship): '
      .. 'the cape left hidden, no show call; found again, hidden', function()
    local w = world(with_remote())
    hide(w, HIDE_YOURS)
    local entity = Fake.ENTITIES + 0xF32F18 + 24 * 194 -- the local avatar's entity record (Fake.world)
    w.space.u32(entity, 0) w.space.u32(entity + 4, 0)
    w.frames(Addon.VERIFY_FRAMES + 2)
    assert(w.instance.state.identity == nil, 'lost')
    for _, c in ipairs(w.engine.visibility) do assert(c.visible == 0, 'no show call') end
    assert(w.engine.hidden(LOCAL_CAPE), 'still hidden')
    w.space.u32(entity, Fake.AVATAR[1]) w.space.u32(entity + 4, Fake.AVATAR[2])
    w.frames(Addon.RESOLVE_FRAMES + 2)
    assert(w.instance.state.identity and w.engine.hidden(LOCAL_CAPE), 'found again, hidden')
end)

check('Hide Cape with Color Matching off: the cape hidden all the same', function()
    local w = world(with_remote())
    w.instance.set_option('mode', 1)
    w.frames(5)
    hide(w, HIDE_YOURS)
    assert(w.engine.hidden(LOCAL_CAPE), 'hidden')
end)

check('a squadmate\'s value with flag 32 hides their cape here whatever this player\'s choice (Off included); without '
      .. 'it, shown again; copies that predate the flag read the rest of the value as before', function()
    local w = world({{id = LOCAL_ID}, {id = REMOTE_ID, value = 'v=1;m=2;f=35;s=0;'}})
    remote_cape(w, 0x206)
    w.frames(Sync.POLL_FRAMES * 2)
    assert(w.engine.hidden(0x206) and not w.engine.hidden(LOCAL_CAPE), 'theirs hidden, this player\'s shown')
    assert(logged(w, 'Hide Cape: player 6\'s cape hidden (unit 206).'), 'noted')
    local o = assert(Sync.decode('v=1;m=2;f=35;s=0;'))
    assert(o.cape_hidden and o.keep_sets and o.recolor_hoods and not o.recolor_cape, 'the other bits as before')
    w.lobby.members[2].value = SHARED
    w.frames(Sync.POLL_FRAMES * 2)
    assert(not w.engine.hidden(0x206), 'their value without it: shown again')
end)

check('Everyone\'s Capes: every squadmate\'s cape hidden here, a respawn\'s new cape within a few frames; back to '
      .. 'Your Cape, theirs shown (they share no flag), this player\'s kept hidden', function()
    local w = world({{id = LOCAL_ID}, {id = REMOTE_ID}})
    remote_cape(w, 0x206)
    hide(w, HIDE_EVERYONE)
    w.frames(Sync.POLL_FRAMES + 2)
    assert(w.engine.hidden(0x206) and w.engine.hidden(LOCAL_CAPE), 'theirs and this player\'s hidden')
    remote_cape(w, 0x207)
    w.frames(2 * Remote.WATCH_FRAMES)
    assert(w.engine.hidden(0x207) and visibility_calls(w, 0x207) == 1, 'their new cape hidden by the watch, once')
    -- their hellpod: the game hides their Helldiver (their helmet, unit 0x200, too), then shows it at the pod's exit:
    -- their cape hidden again on their next watch turn
    local helmet_mask = 0x180000000 + 0x200 * 16 + Fake.MESH_VISIBILITY
    w.space.byte(helmet_mask, 0)
    w.frames(4 * Cloak.GRACE_FRAMES)
    w.space.byte(helmet_mask, 0xFF) w.space.byte(0x180000000 + 0x207 * 16 + Fake.MESH_VISIBILITY, 0xFF)
    w.frames(Remote.WATCH_FRAMES)
    assert(w.engine.hidden(0x207) and visibility_calls(w, 0x207) == 2, 'hidden again on their watch turn')
    hide(w, HIDE_YOURS)
    local f = w.frame() -- the update: their cape shown, no players read (nobody's cape is to be hidden here)
    assert((f.read_into or 0) <= 3 and f.visibility == 1, 'shown without reading the players: ' .. budget.describe(f))
    w.frames(1)
    assert(not w.engine.hidden(0x207) and w.engine.hidden(LOCAL_CAPE), 'theirs shown, this player\'s hidden')
    assert(not w.instance.cloak.others[1], 'no other player watched')
end)

check('Hide Cape pauses with the addon: capes shown, as without the mod', function()
    local w = world({{id = LOCAL_ID}, {id = REMOTE_ID}})
    remote_cape(w, 0x206)
    hide(w, HIDE_EVERYONE)
    w.frames(Sync.POLL_FRAMES + 2)
    w.instance.pause('a test')
    assert(not w.engine.hidden(0x206) and not w.engine.hidden(LOCAL_CAPE), 'both shown')
end)

-- The calls Hide Cape adds, idle (against a twin that has it off): Your Cape, none but one 1-byte read of the hidden
-- cape's mask on the binding check; Everyone's Capes with a squadmate, also one 120-byte read of their units on 1
-- frame in Remote.WATCH_FRAMES (frame % 4 == 2) and the players read on the frame after each lobby poll. While a new
-- cape is young (Cloak.GRACE_FRAMES after it was hidden, longer in a hellpod), one more read: its helmet's mask, this
-- player's every frame.
check('Hide Cape: a new cape\'s helmet is read every frame for its grace frames (one read), then never but on the '
      .. 'binding check (a ship spawn: no hellpod)', function()
    local w, twin = world({{id = LOCAL_ID}, {id = REMOTE_ID}}), world({{id = LOCAL_ID}, {id = REMOTE_ID}})
    hide(w, HIDE_YOURS)
    local hidden_at = w.instance.state.frame
    for _ = 1, 3 * CHECK_FRAMES do
        local s = w.instance.state
        local frame = s.frame + 1
        local check_due = frame >= s.next_check and frame < s.next_verify
        local extra = diff(w.frame(), twin.frame())
        local reads = (frame <= hidden_at + Cloak.GRACE_FRAMES and 1 or 0) + (check_due and 1 or 0)
        local expected = reads > 0 and {read_into = reads} or {}
        assert(helpers.same(extra, expected), 'frame ' .. frame .. ': ' .. budget.describe(extra) .. ', expected '
               .. budget.describe(expected))
    end
end)

check('Hide Cape idle: Your Cape adds one read on the binding check alone; Everyone\'s Capes adds one read on 1 frame '
      .. 'in 4 and the players after each poll; no engine call, no write', function()
    local function squad(value)
        local w = world({{id = LOCAL_ID}, {id = REMOTE_ID}})
        remote_cape(w, 0x206)
        hide(w, value)
        w.frames(Cloak.GRACE_FRAMES + Sync.POLL_FRAMES * 2) -- the capes no longer young
        return w
    end
    for _, case in ipairs({{HIDE_YOURS, false}, {HIDE_EVERYONE, true}}) do
        local w, twin = squad(case[1]), squad(HIDE_OFF)
        assert(w.instance.state.frame == twin.instance.state.frame, 'in step')
        local polls = 0
        for _ = 1, 3 * Sync.POLL_FRAMES do
            local s = w.instance.state
            local frame = s.frame + 1
            local check_due = frame >= s.next_check and frame < s.next_verify
            local after_poll = s.cloak_due
            local extra = diff(w.frame(), twin.frame())
            local reads = (check_due and 1 or 0)
            if case[2] and after_poll then
                polls = polls + 1
                reads = reads + 10 -- Avatar.players with two players (their unit unchanged: no resolve)
            elseif case[2] and frame % Remote.WATCH_FRAMES == 2 then
                reads = reads + 1
            end
            local expected = reads > 0 and {read_into = reads} or {}
            assert(helpers.same(extra, expected), 'case ' .. case[1] .. ', frame ' .. frame .. ': '
                   .. budget.describe(extra) .. ', expected ' .. budget.describe(expected))
        end
        assert(polls == (case[2] and 3 or 0), 'the players read after each poll: ' .. polls)
    end
end)

print('PASS test_sync (' .. passed .. ' checks)')
