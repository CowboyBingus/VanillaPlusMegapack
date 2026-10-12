-- Match Your Colors: the frame step against a simulated game (tests/fake_game.lua) with a local and a remote
-- player: who is recolored, re-equip, previews (the gameplay copies and the UI preview), options, pause, texture
-- lifetime, and the exact calls each kind of frame makes (tests/frame_budget.lua). The job is replaced by a canned one (the real job reads the
-- game's files; tests/test_parity.lua covers it), so these tests need no game install.
-- Usage: luajit tests/test_addon.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_addon.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Avatar, Engine, Recolor, Addon = require('avatar'), require('engine'), require('recolor'), require('addon')
local Preview, Schemes, Sync, Remote = require('preview'), require('schemes'), require('sync'), require('remote')
local Fake = dofile(root .. '/tests/fake_game.lua')
local budget = dofile(root .. '/tests/frame_budget.lua')
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local SPARES = Engine.POOL_SPARES -- free textures made beside one that must be made
local HELMET_LUT, ARMOR_LUT, OTHER_LUT = '962a946e964ebc40', 'a007a73e4082430e', '1111111111111111'
local CAPE_LUT = 'd4cb1423c8d2a2c8' -- the local cape kit 72492837's (Recolor Cape)
local CAPE_TINT = '9c385033ddbaaa60' -- its cape LUT (the tint: src/capes.lua), on the cape's materials
local CAPE_SHEET = '0665210854aa1969' -- its decal sheet (the emblems' colors), on the cape's materials
local SET_HELMET = 0x5e7e7e7e
local FAIL_HELMET = 0x0f0f0f0f -- the canned job fails for this helmet
local HELMET_PATTERN = 'f18dfbb5346732c1'
local VANILLA = {[HELMET_LUT] = 0x190000000, [ARMOR_LUT] = 0x190001000, [OTHER_LUT] = 0x190002000,
                 [HELMET_PATTERN] = 0x190003000, [CAPE_LUT] = 0x190004000, [CAPE_TINT] = 0x190005000,
                 [CAPE_SHEET] = 0x190006000}
local with_patterns = false -- the canned job also plans the helmet's pattern (v11.4)
local with_sheet = false -- the canned job also recolors the cape's emblem in a copy of its decal sheet (round 6)

-- The canned job: the plan changes the target kit's one LUT (a paint scheme: both kits' LUTs, as src/recolor.lua's
-- scheme job). It calls yield 20 times (the fake clock moves 0.1 ms per read, so the 1.5 ms budget makes it span
-- two frames). Every request is kept in `requests`.
local jobs, requests = 0, {}
local HELMET_PIECES = {{piece = {slot = 0, type = 0, body = 3}, materials = {{lut = HELMET_LUT}}, skin = false}}
local ARMOR_PIECES = {{piece = {slot = 2, type = 0, body = 0}, materials = {{lut = ARMOR_LUT}}, skin = false},
                      {piece = {slot = 3, type = 1, body = 3}, materials = {{lut = ARMOR_LUT}}, skin = false},
                      {piece = {slot = 4, type = 0, body = 0}, materials = {{lut = ARMOR_LUT}}, skin = true}}
local CAPE_PIECES = {{piece = {slot = 1, type = 0, body = 3}, materials = {{lut = CAPE_LUT}}, skin = false}}
local function lut_spec() return {width = 23, height = 8, data = ffi.new('float[?]', 23 * 8 * 4)} end
-- The kit records' content as the job's catalogue reads it (src/recolor.lua signature); a test recomposes one.
local RECORDS = {}
local function record_of(id) return RECORDS[id] or string.format('record %08x', id) end
-- Recolor Cape in the canned job: the cape's LUT joins the result, slot 1 the slot range.
local function with_cape(request, result)
    result.signatures = {[request.helmet] = record_of(request.helmet), [request.armor] = record_of(request.armor)}
    if request.capes and (request.cape or 0) ~= 0 then result.signatures[request.cape] = record_of(request.cape) end
    if not request.capes or (request.cape or 0) == 0 then return result end
    result.luts[CAPE_LUT] = lut_spec()
    result.luts[CAPE_TINT] = {width = 16, height = 1, data = ffi.new('float[64]'), cape = true} -- its tint refitted
    if with_sheet then -- src/recolor.lua sheet_spec's (the data's size as a 2048 x 2048 BC3 chain says)
        result.luts[CAPE_SHEET] = {sheet = true, width = 2048, height = 2048, mips = 12, size = 5592432,
                                   data = ffi.new('uint8_t[16]')}
    end
    result.cape_report = string.format('Cape %08x: canned report.', request.cape) -- src/capes.lua Capes.report
    result.targets = result.targets or {result.target}
    result.targets[#result.targets + 1] = {kit = {kit_type = 'Cape'}, pieces = CAPE_PIECES}
    result.first, result.last = math.min(result.first, 1), math.max(result.last, 1)
    result.key = result.key .. string.format(':cape:%08x', request.cape)
    return result
end
local slow_job = false -- 28 pause points: the last slice runs over half the budget (the fake clock: 0.1 ms per call)
local long_job = false -- 80 pause points: a job over several frames, past a UI gate frame
-- Work ahead (src/addon.lua plan_ahead), as src/recolor.lua's job does it: a request without kits builds the pipeline
-- alone; one with kits leaves its analyses and plans made (holder.ahead), so the next job of that request takes one
-- pause point instead of 20.
-- Whether the cape matters to request r: Recolor Cape on, or the cape as the source (src/addon.lua cape_counts).
local function cape_counts(r)
    return r.capes or (r.mode == Recolor.CAPE_SOURCE and (r.scheme or 0) == 0)
end
local function ahead_key(r)
    return table.concat({r.mode, r.scheme or 0, r.helmet, r.armor, r.body, r.keep_hoods and 1 or 0,
                         r.materials and 1 or 0, cape_counts(r) and r.cape or 0}, ':')
end
local function fake_job(_, holder, request, yield)
    jobs = jobs + 1
    requests[#requests + 1] = request
    if not holder.pipeline then -- closes counted (the game-data reader kept while the UI preview is shown)
        local p = {kits = {signature = record_of}, reads = 0, dirty = false, closes = 0}
        function p.close()
            p.closes = p.closes + 1
            if holder.running then p.closed_under_job = true end -- a job still reading through it
        end
        holder.pipeline = p
    end
    holder.ahead = holder.ahead or {}
    holder.running = true
    local made = request.helmet and holder.ahead[ahead_key(request)]
    for _ = 1, made and 1 or (slow_job and 28 or (long_job and 80 or 20)) do
        yield()
        if request.obsolete then return {action = 'obsolete'} end -- as src/recolor.lua's job, at its stage boundaries
    end
    if not request.helmet then return {action = 'prepared'} end
    if request.helmet == FAIL_HELMET then error('canned failure', 0) end
    if request.target == 'prepare' then holder.ahead[ahead_key(request)] = true end
    local scheme = (request.scheme or 0) > 0
    if request.mode == Recolor.OFF and not scheme then return {action = 'restore', reason = 'off'} end
    local cape_mode = request.mode == Recolor.CAPE_SOURCE and not scheme
    if not scheme and not cape_mode and request.keep_sets and request.helmet == SET_HELMET then
        return {action = 'restore', reason = 'complete set'}
    end
    if cape_mode and (request.cape or 0) == 0 then return {action = 'restore', reason = 'no cape'} end
    local key = table.concat({request.mode, request.scheme or 0, request.helmet, request.armor, request.body,
                              request.keep_hoods and 1 or 0, request.materials and 1 or 0}, ':')
    local helmet_target = {kit = {kit_type = 'Helmet'}, pieces = HELMET_PIECES}
    local armor_target = {kit = {kit_type = 'Armor'}, pieces = ARMOR_PIECES}
    if cape_mode then -- the cape is the source (src/recolor.lua): both items, the cape as it is, signed by its record
        local result = {action = 'apply', key = string.format('capesrc:%08x:', request.cape) .. key,
                        luts = {[HELMET_LUT] = lut_spec(), [ARMOR_LUT] = lut_spec()}, first = 0, last = 9,
                        target = helmet_target, targets = {helmet_target, armor_target}}
        result.signatures = {[request.helmet] = record_of(request.helmet), [request.armor] = record_of(request.armor),
                             [request.cape] = record_of(request.cape)}
        return result
    end
    if scheme then
        return with_cape(request, {action = 'apply', key = key, luts = {[HELMET_LUT] = lut_spec(),
                         [ARMOR_LUT] = lut_spec()}, first = 0, last = 9, target = helmet_target,
                         targets = {helmet_target, armor_target}})
    end
    local helmet = request.mode == Recolor.HELMET_FROM_ARMOR
    return with_cape(request, {action = 'apply', key = key, luts = {[helmet and HELMET_LUT or ARMOR_LUT] = lut_spec()},
            patterns = with_patterns and helmet and {[HELMET_PATTERN] = {width = 3, height = 1,
                                                                         data = ffi.new('float[12]')}} or nil,
            first = helmet and 0 or 1, last = helmet and 0 or 9, target = helmet and helmet_target or armor_target})
end
local function tracked_job(deps, holder, request, yield)
    local ok, result = pcall(fake_job, deps, holder, request, yield)
    holder.running = false
    if not ok then error(result, 0) end
    return result
end
local TestRecolor = setmetatable({job = tracked_job}, {__index = Recolor})

-- A fresh world: local helmet unit 0x100 (slot 0), armor units 0x101 (torso) and 0x102 (hips undergarment),
-- 0x103 (a piece with skin tones, left leg); the remote player's helmet 0x200 uses the same helmet LUT. options.lobby
-- {local_id, members} adds the squad's PlayFab lobby (Fake.lobby) and the sync modules (src/sync.lua,
-- src/remote.lua).
local function setup(options)
    options = options or {}
    local space = Fake.world({previews = options.previews, ui = options.ui, players = options.players,
        helmet = options.helmet, no_manager = options.no_manager,
        local_units = {[{0, 0}] = 0x100, [{0, 1}] = 0x106, [{0, 2}] = 0x101, [{1, 3}] = 0x102, [{0, 4}] = 0x103},
        remote_units = {[{0, 0}] = 0x200}})
    local engine = Fake.engine(space, VANILLA)
    engine.unit(0x100, HELMET_LUT, nil, options.patterns and HELMET_PATTERN or nil)
    engine.unit(0x101, ARMOR_LUT) engine.unit(0x102, ARMOR_LUT)
    engine.unit(0x103, ARMOR_LUT) engine.unit(0x200, HELMET_LUT)
    engine.unit(0x106, CAPE_LUT, nil, nil, CAPE_TINT, CAPE_SHEET) -- the cape (slot 1), its cape LUT and sheet too
    local memory = Fake.memory(space)
    local memory_calls, native_calls = budget.wrap(memory), budget.wrap(engine.native)
    local lines = {}
    local m = {Avatar = Avatar, Preview = Preview, Recolor = TestRecolor, Engine = Engine, Schemes = Schemes,
               memory = memory, native = engine.native, game = Fake.GAME, Files = options.files,
               note = function(l) lines[#lines + 1] = l end}
    local lobby, lobby_calls = nil, {}
    if options.lobby then
        lobby = Fake.lobby(space, options.lobby.local_id, options.lobby.members)
        lobby_calls = budget.wrap(lobby.api)
        m.Sync, m.Remote, m.natives = Sync, Remote, options.lobby.natives or lobby.natives
    end
    local instance = Addon.new(m)
    local world = {space = space, engine = engine, memory = memory, instance = instance, lines = lines, lobby = lobby}
    -- One frame: the calls it made to memory, to the engine and to PlayFab, merged ('read_into', 'alive',
    -- 'members', ...).
    function world.frame()
        for _, calls in ipairs({memory_calls, native_calls, lobby_calls}) do
            for k in pairs(calls) do calls[k] = nil end
        end
        instance.step()
        if lobby then lobby.tick() end -- the game's update after the mods: PlayFab's lobby state processed
        local all = {}
        for _, calls in ipairs({memory_calls, native_calls, lobby_calls}) do
            for k, v in pairs(calls) do all[k] = (all[k] or 0) + v end
        end
        return all
    end
    function world.frames(count)
        local last
        for _ = 1, count do last = world.frame() end
        return last
    end
    function world.bound(unit) -- the LUT object of each of the unit's materials
        local out = {}
        for i, m in ipairs(engine.units[unit].materials) do out[i] = engine.binding(m.material) end
        return out
    end
    return world
end

local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end
local function expect(frame, expected, label)
    assert(same(frame, expected), label .. ': ' .. budget.describe(frame) .. ', expected ' .. budget.describe(expected))
end

-- Calls of the exact frame kinds (Steam build 25480438 layout). Idle: the avatar's unit bytes, plus the
-- preview slot's count when the local player has a slot. Every 30th frame also checks one recolored material
-- per runtime texture: two reads each (one texture for the helmet).
local IDLE = {read_into = 1}
local IDLE_PREVIEW = {read_into = 2}
local CHECK = {read_into = 3}
local CHECK_PREVIEW = {read_into = 4}
-- A planned pattern is one more runtime texture; the 30-frame check reads one probe in turn (two reads) whatever the
-- number of textures, so each of the two is checked every 60 frames.

-- Over `count` frames: how many were exactly `idle`, exactly `check`, and other (the 2-second chain check,
-- reads and alive() only).
local function classify(w, count, idle, check)
    local n = {idle = 0, check = 0, other = 0}
    for _ = 1, count do
        local f = w.frame()
        if same(f, idle) then
            n.idle = n.idle + 1
        elseif same(f, check) then
            n.check = n.check + 1
        else
            n.other = n.other + 1
            for k in pairs(f) do assert(k == 'read_into' or k == 'alive', 'unexpected call on a check frame: ' .. k) end
        end
    end
    return n
end

check('no player manager (title screen): nothing between resolves, one resolve every 15 frames, nothing prepared',
      function()
    local w = setup({no_manager = true})
    local first = w.frame()
    assert(first.read_into == 1, 'resolve stops at the player manager: ' .. budget.describe(first))
    for i = 2, 15 do expect(w.frame(), {}, 'frame ' .. i) end
    assert(w.frame().read_into, 'frame 16 resolves again')
    assert(#w.engine.created == 0 and jobs == 0, 'nothing applied, nothing prepared')
end)

local function logged(w, text)
    for _, line in ipairs(w.lines) do if line:find(text, 1, true) then return line end end
    return nil
end

-- The local avatar's entity record (Fake.world: entity 194) as an avatar, or (made false) another entity: the
-- player's kits read while its Helldiver is not made yet, as on a loading screen ('not an avatar entity').
local function avatar_made(w, made)
    local at = Fake.ENTITIES + 0xF32F18 + 24 * 194
    w.space.u32(at, made and Fake.AVATAR[1] or 0)
    w.space.u32(at + 4, made and Fake.AVATAR[2] or 0)
end

check('a world loading (a player manager, no players): the pipeline is prepared once, from the frame after the '
      .. 'resolve; the resolves read what they read before, every 15 frames', function()
    local w = setup({players = 0})
    local count = jobs
    local first = w.frame()
    assert(first.read_into and first.read_into <= 3, 'resolve stops at the player count: ' .. budget.describe(first))
    -- frames 2-15: the work ahead from frame 2 (the pipeline reads files: no memory read, only its budget's clock)
    for i = 2, 15 do
        for k in pairs(w.frame()) do assert(k == 'time', 'frame ' .. i .. ': ' .. k) end
    end
    local r = requests[#requests]
    assert(jobs == count + 1 and r.target == 'prepare' and r.helmet == nil, 'the pipeline alone')
    assert(w.frame().read_into <= 3, 'frame 16 resolves again')
    w.frames(45)
    assert(jobs == count + 1 and #w.engine.created == 0, 'prepared once, nothing applied')
    assert(logged(w, 'Prepared ahead of the Helldiver: analysis cache and game data'), 'logged')
end)

check('kits known before the Helldiver (loading): their plans are prepared on the next frame, once, and their '
      .. 'textures made then (POOL_STOCK per LUT: the first apply on the ship made 20 in a 7.8 ms frame, KB '
      .. 'match-your-colors-stress-test); the Helldiver is recolored on the frame after it was found, by a job of one '
      .. 'short slice (under APPLY_ALONE: applied at once), making no texture', function()
    local w = setup()
    avatar_made(w, false)
    local count = jobs
    w.frames(2) -- the resolve reads the kits, the next frame starts the work ahead
    local r = requests[#requests]
    assert(jobs == count + 1 and r.target == 'prepare' and r.helmet == 0xa5574ac2 and r.armor == 0x0ade6719
           and r.mode == Recolor.HELMET_FROM_ARMOR, 'the kits worn, with the options')
    w.frames(29) -- frames 3-31: the job ends, its textures made; frames 16 and 31 resolve again, still no Helldiver
    -- its one LUT's size POOL_STOCK times, every other LUT size of the game POOL_SPARES + 1 times
    local stock = Engine.POOL_STOCK + (#Engine.POOL_SIZES - 1) * (Engine.POOL_SPARES + 1)
    assert(jobs == count + 1 and #w.engine.created == stock and w.instance.pool.free() == stock,
           'prepared once, its sizes stocked: ' .. #w.engine.created)
    avatar_made(w, true)
    w.frames(15) -- frame 46 finds the Helldiver
    assert(w.instance.state.identity and not w.instance.state.job, 'found, no job yet')
    local f = w.frame()
    assert(jobs == count + 2 and requests[#requests].target == 'avatar' and not w.instance.state.job,
           'its job ended in its first slice')
    assert(not f.create and #w.engine.created == stock, 'no texture made on the Helldiver\'s frames')
    local ours = {}
    for _, texture in ipairs(w.engine.created) do ours[texture.object] = true end
    for _, object in ipairs(w.bound(0x100)) do assert(ours[object], 'recolored on that frame, with a stocked texture') end
    assert(logged(w, '1 frame after the Helldiver was found'), 'logged: ' .. tostring(logged(w, 'Recolored')))
    assert(logged(w, 'Prepared ahead of the Helldiver: plans of helmet a5574ac2, armor 0ade6719')
           and logged(w, stock .. ' textures made ahead'), 'logged ahead')
end)

check('work ahead: nothing while nothing local is recolored; kits that change before the Helldiver is made get a '
      .. 'job of their own; a failure is noted, not counted, not repeated', function()
    local w = setup({players = 0})
    w.instance.set_option('mode', Recolor.OFF)
    local count = jobs
    w.frames(31)
    assert(jobs == count, 'Color Matching off, no paint scheme: no pipeline ahead')
    w = setup()
    avatar_made(w, false)
    count = jobs
    w.frames(16)
    w.space.u32(Fake.CUSTOMIZATION + 2416, 0x0b0b0b0b) -- the game applies a loadout: another helmet
    avatar_made(w, true)
    w.frames(16) -- frame 31 finds the Helldiver in the new helmet, frame 32 starts its job
    assert(requests[#requests].target == 'avatar' and requests[#requests].helmet == 0x0b0b0b0b
           and w.instance.state.job, 'not prepared: a full job')
    w = setup({helmet = FAIL_HELMET})
    avatar_made(w, false)
    count = jobs
    w.frames(46)
    assert(jobs == count + 1 and logged(w, 'Preparing ahead of the Helldiver failed: canned failure'), 'noted once')
    assert(next(w.instance.state.failures) == nil, 'not counted')
end)

check('stand-in kits while loading (0xffffffff; live 2026-10-08: the helmet real first, the armor some frames later) '
      .. 'are not prepared; the real ones are once the record shows them, and the Helldiver is recolored at once',
      function()
    local w = setup()
    w.instance.set_option('recolor_cape', true)
    avatar_made(w, false)
    w.space.u32(Fake.CUSTOMIZATION + 2424, 0xffffffff) -- the armor still a stand-in
    local count = #requests
    w.frames(16) -- frames 1 and 16 resolve: stand-ins; the pipeline alone is prepared (a world is loading)
    for i = count + 1, #requests do assert(requests[i].helmet == nil, 'no kits prepared: ' .. tostring(requests[i].armor)) end
    w.space.u32(Fake.CUSTOMIZATION + 2424, 0x0ade6719)
    w.space.u32(Fake.CUSTOMIZATION + 2420, 0xffffffff) -- now the cape (Recolor Cape on)
    w.frames(16) -- frame 31 resolves: still a stand-in; frame 32 would start work for it
    assert(requests[#requests].helmet == nil, 'a stand-in cape counts with Recolor Cape on')
    w.space.u32(Fake.CUSTOMIZATION + 2420, 0x72492837)
    w.frames(15) -- frame 46 resolves: the real kits, prepared from frame 47
    local r = requests[#requests]
    assert(r.target == 'prepare' and r.armor == 0x0ade6719 and r.cape == 0x72492837, 'the real kits prepared')
    assert(not logged(w, 'Preparing ahead of the Helldiver failed'), 'nothing failed on the stand-ins')
    avatar_made(w, true)
    w.frames(14) -- frame 61 finds the Helldiver
    w.frames(2) -- its job of one slice (the cape's part too: over APPLY_ALONE), then its apply on a frame of its own
    assert(logged(w, '2 frames after the Helldiver was found'), 'recolored two frames later')
end)

check('work ahead starts on the frame after its resolve even when another resolve is due then (it waits for the job)',
      function()
    local cadence = Addon.RESOLVE_FRAMES
    Addon.RESOLVE_FRAMES = 1
    local w = setup()
    avatar_made(w, false)
    local count = jobs
    w.frames(2)
    Addon.RESOLVE_FRAMES = cadence
    assert(jobs == count + 1 and requests[#requests].target == 'prepare', 'started on frame 2')
end)

check('the game-data reader stays open between preview jobs while the preview is shown (the next item read the '
      .. "index and the archives' chunk tables again: about 25 of a new armor's 62 frames waited on the disk, live "
      .. '2026-10-08); it closes when the preview closes, after KEEP_FRAMES frames without a job, when the Helldiver is '
      .. 'lost, and after a job while the preview is hidden: on the next binding check without a job, not on the frame '
      .. 'of the apply (0.35 ms in game with 3-4 archives open; KB match-your-colors-stress-test)', function()
    local w = setup({ui = true})
    w.frames(4) -- the avatar's job and its apply, the preview hidden
    local s, p = w.instance.state, w.instance.state.holder.pipeline
    local closes = p.closes
    assert(s.reader_kept, 'not closed on the frame of the apply: due')
    w.instance.set_option('match_materials', true) -- a job before the binding check takes the reader as it is
    w.frames(4)
    assert(p.closes == closes and s.reader_kept and not s.job, 'the next job took it open; due again after it')
    w.frames(Addon.CHECK_FRAMES)
    assert(p.closes == closes + 1 and not s.reader_kept, 'closed by the next binding check without a job')
    closes = p.closes
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(p.closes == closes and s.reader_kept, 'kept after the preview job')
    w.frames(Addon.CHECK_FRAMES + 1)
    assert(p.closes == closes and s.reader_kept, 'kept past a binding check while the preview is shown')
    Fake.show_ui(w.space, 1, {helmet = 0x0c0c0c0c, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(p.closes == closes and s.reader_kept, "still kept after the next item's job")
    Fake.show_ui(w.space, 1, nil)
    w.frames(2)
    assert(p.closes == closes + 1 and not s.reader_kept, 'closed with the preview')
    Fake.show_ui(w.space, 1, {helmet = 0x0d0d0d0d, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(p.closes == closes + 1 and s.reader_kept, 'kept again')
    w.frames(Addon.KEEP_FRAMES + Addon.CHECK_FRAMES)
    assert(p.closes == closes + 2 and not s.reader_kept, 'closed after KEEP_FRAMES frames without a job')
    Fake.show_ui(w.space, 1, {helmet = 0x0e0e0e0e, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(p.closes == closes + 2 and s.reader_kept, 'kept for the next item')
    -- the preview closes while a job for a new item runs: the job keeps its reader until it ends, then it is due
    long_job = true -- running past the next UI gate frame, where the closed preview is seen
    Fake.show_ui(w.space, 1, {helmet = 0x0f0f0f1f, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    while not s.job do w.frame() end
    Fake.show_ui(w.space, 1, nil)
    w.frames(8 + Addon.CHECK_FRAMES)
    long_job = false
    assert(not p.closed_under_job and p.closes == closes + 3 and not s.reader_kept, 'closed after its job ended')
    Fake.show_ui(w.space, 1, {helmet = 0x0e0e0e0e, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(s.reader_kept, 'kept again')
    avatar_made(w, false) -- the Helldiver lost (the chain check every 120 frames)
    w.frames(Addon.VERIFY_FRAMES + 1)
    assert(p.closes == closes + 4 and not s.reader_kept and not s.identity, 'closed when the Helldiver is lost')
end)

check('a closed reader\'s file handles are closed CLOSES_PER_CHECK at a time on binding checks, not on the frame it '
      .. 'closes (in game 2.3 ms after cold Armory browsing; KB match-your-colors-stress-test)', function()
    local queued, drains = 0, {}
    local files = {abandon = function() queued = 0 end}
    function files.close_some(count)
        local closed = math.min(count, queued)
        queued = queued - closed
        drains[#drains + 1] = closed
        return queued
    end
    local w = setup({files = files})
    w.frames(4) -- resolve, the job, its apply: its reader due
    local s, p = w.instance.state, w.instance.state.holder.pipeline
    local close = p.close
    p.close = function() queued = 10 close() end -- ten archives open
    while not s.closing do w.frame() end -- the next binding check closes the reader: its handles queued
    assert(#drains == 1 and drains[1] == Addon.CLOSES_PER_CHECK and queued == 10 - Addon.CLOSES_PER_CHECK,
           'the first few on the same check: ' .. table.concat(drains, ','))
    w.frames(Addon.CHECK_FRAMES - 1)
    assert(#drains == 1, 'none between checks')
    w.frames(2 * Addon.CHECK_FRAMES)
    assert(queued == 0 and not s.closing and #drains == 3, 'all closed over three checks: ' .. table.concat(drains, ','))
    w.frames(Addon.CHECK_FRAMES)
    assert(#drains == 3, 'nothing asked once all are closed')
end)

check('a respawn: kits already applied are not prepared again while the Helldiver is not made', function()
    local w = setup()
    w.frames(4) -- the job, then its apply
    local count = jobs
    avatar_made(w, false) -- the dead Helldiver's avatar gone, the player's unit not cleared yet
    w.frames(Addon.VERIFY_FRAMES + 31)
    assert(w.instance.state.identity == nil and jobs == count, 'lost, nothing prepared')
end)

check('the local helmet takes the plan; the remote player and the armor keep theirs', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local texture = w.engine.created[1]
    assert(texture and texture.alive, 'one texture')
    for _, object in ipairs(w.bound(0x100)) do assert(object == texture.object, 'local helmet recolored') end
    for _, object in ipairs(w.bound(0x200)) do assert(object == VANILLA[HELMET_LUT], 'remote helmet untouched') end
    for _, object in ipairs(w.bound(0x101)) do assert(object == VANILLA[ARMOR_LUT], 'armor untouched') end
    assert(#w.engine.created == 1 + SPARES and w.instance.pool.free() == SPARES,
           'one texture bound, the spares made in the same frame are free')
end)

check('idle frames: one read (+1 for the body-copy slot on odd frames); +2 every 30 frames; the chain every 120',
      function()
    for _, previews in ipairs({false, true}) do
        local w = setup({previews = previews})
        w.frames(5)
        local idle, checks, other = 0, 0, 0
        for _ = 1, 240 do
            local f = w.frame()
            local base = (previews and w.instance.state.frame % 2 == 1) and 2 or 1
            if same(f, {read_into = base}) then
                idle = idle + 1
            elseif same(f, {read_into = base + 2}) then -- one binding probe, whatever the textures
                checks = checks + 1
            else
                other = other + 1
                for k in pairs(f) do assert(k == 'read_into', 'the chain check calls nothing else: ' .. k) end
            end
        end
        -- 240 frames: 8 binding checks and 2 chain checks, never on one frame (a chain check moves the binding
        -- check to the next frame).
        assert(idle + checks + other == 240 and other == 2 and checks >= 7 and checks <= 8,
               string.format('idle %d, check %d, other %d', idle, checks, other))
    end
end)

check('the game putting the original LUT back is noticed within 30 frames and recolored again', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local texture = w.engine.created[1]
    local material = w.engine.units[0x100].materials[1].material
    w.space.u64(material + 0x48, VANILLA[HELMET_LUT]) -- as the game's own set_texture would
    w.frames(33)
    assert(w.engine.binding(material) == texture.object, 'recolored again with the same texture')
    local seen = false
    for _, line in ipairs(w.lines) do if line:find('original color texture back', 1, true) then seen = true end end
    assert(seen and #w.engine.created == 1 + SPARES, 'logged, no new texture')
end)

check('re-equip: the new helmet unit is recolored with the same texture, the old one retired never', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local texture = w.engine.created[1]
    w.engine.units[0x100].alive = false
    w.engine.unit(0x104, HELMET_LUT)
    w.space.u32(Fake.local_unit_at(0, 0), 0x104)
    w.frames(3)
    for _, object in ipairs(w.bound(0x104)) do assert(object == texture.object, 'new unit recolored') end
    assert(#w.engine.created == 1 + SPARES and texture.alive, 'same texture kept')
end)

check('a job is applied on the frame after its last slice, on its own, the last slice long or short (APPLY_ALONE; '
      .. 'before v1.4\'s performance pass a slice under half the budget was applied at once)', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    slow_job = true
    w.instance.set_option('match_materials', true)
    local first, last, apply = w.frame(), w.frame(), w.frame()
    slow_job = false
    assert(not first.set_resource and not last.set_resource and apply.set_resource and not w.instance.state.job,
           'the apply alone on the frame after the job ended: ' .. budget.describe(last) .. ' / '
           .. budget.describe(apply))
    w.instance.set_option('match_materials', false)
    local slice, short, ended = w.frame(), w.frame(), w.frame()
    assert(not slice.set_resource and not short.set_resource and ended.set_resource,
           'a short last slice too: ' .. budget.describe(short) .. ' / ' .. budget.describe(ended))
end)

check('a new plan binds its textures over the plan before\'s instead of putting the vanilla ones back first, and '
      .. 'reads each material\'s bindings once: a paint scheme over both kits applies with 39 reads, 8 binds and 4 '
      .. 'commits (before v1.4\'s performance pass, the job\'s last slice in the same frame: 51 reads, 14 binds, '
      .. '7 commits; KB match-your-colors-stress-test); what the plan does not bind is put back', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.instance.set_option('match_materials', true)
    w.frames(6)
    w.instance.set_option('mode', Recolor.ARMOR_FROM_HELMET)
    w.frames(6)
    for _, object in ipairs(w.bound(0x100)) do assert(object == VANILLA[HELMET_LUT], 'the helmet put back') end
    local restored = w.instance.controller.restored
    w.instance.set_option('scheme', 3)
    local f, n = nil, 0
    repeat f, n = w.frame(), n + 1 until f.set_resource or n == 12
    expect(f, {alive = 8, can_get = 2, commit = 4, get = 2, material = 8, materials = 4, mesh = 4, meshes = 4,
               read_into = 39, set_resource = 8, time = 5, update = 2}, 'the apply frame')
    assert(n == 3, 'applied on the frame after the job\'s last: frame ' .. n)
    local ours = {}
    for _, texture in pairs(w.instance.controller.textures) do ours[texture.object] = true end
    for _, unit in ipairs({0x100, 0x101, 0x102}) do
        for _, object in ipairs(w.bound(unit)) do assert(ours[object], 'every material on the new plan\'s texture') end
    end
    assert(#w.instance.controller.bindings == 8 and w.instance.controller.restored == restored,
           'its 8 bindings, none put back: ' .. #w.instance.controller.bindings .. ', '
           .. (w.instance.controller.restored - restored))
end)

check('a respawn (new units, same kits and options) is rebound at once with the applied result: no job, no '
      .. 'resolve beyond the chain check; dead units\' bindings dropped', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local texture, count = w.engine.created[1], #requests
    w.engine.units[0x100].alive = false
    w.engine.unit(0x104, HELMET_LUT)
    w.space.u32(Fake.local_unit_at(0, 0), 0x104)
    local f = w.frame() -- the watch sees the change: the chain check and the rebind, this frame
    for _, object in ipairs(w.bound(0x104)) do assert(object == texture.object, 'new unit recolored on this frame') end
    assert(#requests == count and not w.instance.state.job, 'no job for a units-only change')
    for _, b in ipairs(w.instance.controller.bindings) do assert(b.unit ~= 0x100, 'the dead unit\'s bindings dropped') end
    -- alive(): listing the new unit's materials, then the prune once per unit (the dead one and the new one)
    assert(f.alive == 3, 'alive() once per unit: ' .. budget.describe(f))
    w.instance.set_option('match_materials', true)
    w.frames(2)
    assert(#requests > count, 'an options change still re-plans')
end)

check('one heavy periodic check per frame: a chain check (here after a unit change) moves the binding check to the '
      .. 'next frame', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local s = w.instance.state
    while s.next_check ~= s.frame + 1 do w.frame() end -- the next frame is a binding check's
    local due = s.next_check
    w.engine.units[0x100].alive = false
    w.engine.unit(0x108, HELMET_LUT)
    w.space.u32(Fake.local_unit_at(0, 0), 0x108) -- a respawn on that frame: the chain check runs
    w.frame()
    assert(s.verified_at == s.frame and s.next_check == due, 'the binding check waited a frame')
    w.frame()
    assert(s.next_check == s.frame + Addon.CHECK_FRAMES, 'and ran on the next one')
end)

check('another mod\'s texture on a material (a transmog\'s own LUT) is never bound over, restored or fought: the '
      .. 'recolor check does not reassert', function()
    local FOREIGN = 0x1A0000000
    local w = setup({ui = false})
    local material = w.engine.units[0x100].materials[1].material
    w.space.u64(material + 0x48, FOREIGN) -- the other mod's texture, before the first recolor
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local other = w.engine.units[0x100].materials[2].material
    assert(w.engine.binding(material) == FOREIGN, 'its material keeps the other mod\'s texture')
    assert(w.engine.binding(other) ~= VANILLA[HELMET_LUT], 'the other material is recolored')
    local recolored = w.engine.binding(other)
    w.space.u64(other + 0x48, FOREIGN + 0x100) -- the other mod binds its texture after the recolor
    w.frames(65) -- two binding checks
    assert(w.engine.binding(other) == FOREIGN + 0x100 and recolored ~= FOREIGN + 0x100, 'not reasserted')
    w.instance.set_option('match_materials', true) -- a new plan binds over the plan before's textures only
    w.frames(6)
    assert(w.engine.binding(other) == FOREIGN + 0x100 and w.engine.binding(material) == FOREIGN,
           'a new plan does not take over a slot holding another texture than the plan before\'s')
    w.instance.set_option('mode', Recolor.OFF)
    w.frames(3)
    assert(w.engine.binding(material) == FOREIGN and w.engine.binding(other) == FOREIGN + 0x100,
           'Off restores only its own textures')
end)

check('a transmog recomposes the worn record (same id, other pieces): a respawn then gets a job, not the old '
      .. 'result', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local count = #requests
    RECORDS[0x0ade6719] = 'record 0ade6719 composed with another look'
    w.engine.units[0x100].alive = false
    w.engine.unit(0x109, HELMET_LUT)
    w.space.u32(Fake.local_unit_at(0, 0), 0x109)
    w.frames(3)
    RECORDS[0x0ade6719] = nil
    assert(#requests == count + 1, 'one job for the recomposed record: ' .. (#requests - count))
end)

check('a binding check costs one probe (two reads) whatever the number of textures (a paint scheme: two)', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.instance.set_option('scheme', 3)
    w.frames(4)
    assert(w.instance.controller.probes == 2, 'helmet and armor textures tracked: ' .. w.instance.controller.probes)
    local n = classify(w, 120, IDLE, CHECK)
    assert(n.check >= 3 and n.idle + n.check + n.other == 120, string.format('idle %d, check %d, other %d', n.idle,
           n.check, n.other))
end)

check('the UI preview showing new units of the same kits is rebound at once, without a job', function()
    local shown = {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0} -- a hovered helmet (HOVERED is declared below)
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, shown, {[{0, 0}] = 0x300})
    w.frames(7)
    local first, count = w.bound(0x300)[1], #requests
    assert(first ~= VANILLA[HELMET_LUT], 'the preview recolored')
    w.engine.units[0x300].alive = false
    w.engine.unit(0x303, HELMET_LUT)
    Fake.show_ui(w.space, 1, shown, {[{0, 0}] = 0x303})
    w.frame()
    assert(w.bound(0x303)[1] == first and #requests == count, 'the same texture on the new unit, no new job')
end)

check('preview entries of the local player are recolored, the remote player\'s are not', function()
    local w = setup({previews = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x105, HELMET_LUT)
    w.engine.unit(0x205, HELMET_LUT)
    w.space.u32(Fake.preview_entry_at(1, 0) + 12, 0x105) -- local slot, entry 0, helmet
    w.space.u32(Fake.PREVIEWS + 2080 + 2184 + 64, 1)
    w.space.u32(Fake.preview_entry_at(0, 0) + 12, 0x205) -- remote slot
    w.space.u32(Fake.PREVIEWS + 2080 + 64, 1)
    w.frames(3)
    local texture = w.engine.created[1]
    for _, object in ipairs(w.bound(0x105)) do assert(object == texture.object, 'local preview recolored') end
    for _, object in ipairs(w.bound(0x205)) do assert(object == VANILLA[HELMET_LUT], 'remote preview untouched') end
    local idle, others = 0, 0
    for _ = 1, 30 do
        local f = w.frame()
        local base = w.instance.state.frame % 2 == 1 and 2 or 1
        if same(f, {read_into = base}) then idle = idle + 1 elseif not same(f, {read_into = base + 2}) then
            others = others + 1
        end
    end
    assert(idle >= 28 and others == 0, 'idle with one local preview entry: units, and on odd frames count and entries '
           .. 'in one read')
end)

check('Off puts the vanilla LUT back; the texture is free four frames later and the next plan refills it', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local texture = w.engine.created[1]
    w.instance.set_option('mode', Recolor.OFF)
    w.frames(3) -- the job spans two frames, restore on the second
    for _, object in ipairs(w.bound(0x100)) do assert(object == VANILLA[HELMET_LUT], 'helmet back to vanilla') end
    assert(w.instance.pool.free() == SPARES, 'not free at once')
    w.frames(4)
    assert(texture.alive and w.instance.pool.free() == SPARES + 1, 'free after the retire delay, not destroyed')
    w.instance.set_option('mode', Recolor.HELMET_FROM_ARMOR)
    local calls = {}
    for _ = 1, 3 do for k, v in pairs(w.frame()) do calls[k] = (calls[k] or 0) + v end end
    assert(not calls.create and calls.update == 1, 'one texture refilled, none made: ' .. budget.describe(calls))
    local object = w.bound(0x100)[1]
    assert(object ~= VANILLA[HELMET_LUT] and #w.engine.created == 1 + SPARES, 'recolored with a pooled texture')
end)

check('armor matches helmet: armor units recolored, a piece with skin tones too (user ticket 2026-10-09: the PH-9 '
      .. 'Predator\'s shirt and the RS-40 Beast of Prey\'s sleeves kept their colors), the helmet untouched', function()
    local w = setup()
    w.instance.set_option('mode', Recolor.ARMOR_FROM_HELMET)
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local texture = w.engine.created[1]
    for _, unit in ipairs({0x101, 0x102}) do
        for _, object in ipairs(w.bound(unit)) do assert(object == texture.object, 'armor unit recolored') end
    end
    for _, object in ipairs(w.bound(0x103)) do assert(object == texture.object, 'the piece with skin tones recolored') end
    for _, object in ipairs(w.bound(0x100)) do assert(object == VANILLA[HELMET_LUT], 'helmet untouched') end
end)

check('switching direction restores the old target before recoloring the new one', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local first = w.engine.created[1]
    w.instance.set_option('mode', Recolor.ARMOR_FROM_HELMET)
    w.frames(3)
    for _, object in ipairs(w.bound(0x100)) do assert(object == VANILLA[HELMET_LUT], 'helmet restored') end
    local armor = w.bound(0x101)[1]
    assert(armor ~= VANILLA[ARMOR_LUT] and armor ~= first.object, 'armor recolored with a spare')
    for _, object in ipairs(w.bound(0x102)) do assert(object == armor, 'the same texture on the other armor unit') end
    assert(#w.engine.created == 1 + SPARES, 'no texture made: the armor plan refilled a spare')
    w.frames(4)
    assert(first.alive and w.instance.pool.free() == SPARES, 'the helmet texture free again, not destroyed')
end)

check('complete sets stay vanilla while the option is on', function()
    local w = setup({helmet = SET_HELMET})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    assert(#w.engine.created == 0, 'no texture for a complete set')
    w.instance.set_option('keep_sets', false)
    w.frames(3)
    assert(#w.engine.created == 1 + SPARES, 'recolored once the option is off')
end)

check('the hood and material toggles reach the job: each change re-plans once, refilling a pooled texture', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local last = requests[#requests]
    assert(last.keep_hoods == false and last.materials == false, 'defaults: hoods recolored, materials kept')
    local texture = w.bound(0x100)[1]
    local before = #requests
    w.instance.set_option('recolor_hoods', false)
    w.frames(3)
    last = requests[#requests]
    assert(#requests == before + 1 and last.keep_hoods == true and last.materials == false, 'hoods kept: one job')
    w.instance.set_option('match_materials', true)
    w.frames(3)
    last = requests[#requests]
    assert(#requests == before + 2 and last.keep_hoods == true and last.materials == true, 'materials: one job')
    local object = w.bound(0x100)[1]
    assert(object ~= VANILLA[HELMET_LUT] and object ~= texture and #w.engine.created == 1 + SPARES,
           'each new plan bound a pooled texture, none made')
    w.instance.set_option('recolor_hoods', 1)
    w.frames(3)
    assert(#requests == before + 2, 'a value that is no boolean changes nothing')
    local n = classify(w, 120, IDLE, CHECK)
    assert(n.idle + n.check + n.other == 120 and n.check >= 3, 'idle frames as before the options')
end)

check('a hood or material toggle changed while a job runs discards its result', function()
    for _, name in ipairs({'recolor_hoods', 'match_materials'}) do
        local w = setup()
        w.frame() -- resolve
        w.frame() -- the job starts and yields
        local value = name == 'match_materials'
        w.instance.set_option(name, value)
        w.frame() -- the job ends: its options are stale, so nothing is applied
        assert(#w.engine.created == 0, name .. ': stale result not applied')
        w.frames(4)
        local last = requests[#requests]
        assert(#w.engine.created == 1 + SPARES and (name == 'recolor_hoods' and last.keep_hoods or last.materials),
               name .. ': applied with the new option')
        w.instance.set_option(name, not value)
    end
end)

check('the UI preview\'s job carries the hood and material options too', function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.instance.set_option('recolor_hoods', false)
    w.instance.set_option('match_materials', true)
    w.frames(3)
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    w.frames(7)
    local last = requests[#requests]
    assert(last.target == 'ui' and last.keep_hoods == true and last.materials == true, 'preview request options')
    assert(w.bound(0x300)[1] ~= VANILLA[HELMET_LUT], 'preview recolored')
end)

check('a pause restores at once; the next frames start over', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.instance.pause('test')
    for _, object in ipairs(w.bound(0x100)) do assert(object == VANILLA[HELMET_LUT], 'vanilla during the pause') end
    w.frames(10)
    local object = w.bound(0x100)[1]
    assert(object ~= VANILLA[HELMET_LUT] and #w.engine.created == 1 + SPARES, 'recolored again from the pool')
end)

check('kits that change while a job runs discard its result', function()
    local w = setup()
    w.frame() -- resolve
    w.frame() -- job starts, yields
    w.space.u32(Fake.CUSTOMIZATION + 2416, 0x99999999) -- another helmet before the job ends
    w.frame() -- job ends: discarded, a new job starts on the next frame
    assert(#w.engine.created == 0, 'stale result not applied')
    w.frames(4)
    assert(#w.engine.created == 1 + SPARES, 'applied for the new kits')
end)

-- UI preview (the Armory CHARACTER view): helmet 0x0b0b0b0b is hovered, so the preview shows another pair.
local HOVERED = {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0}

check("the local UI preview takes its own plan (a hovered helmet); the remote player's preview stays", function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local avatar_texture = w.engine.created[1]
    w.engine.unit(0x300, HELMET_LUT) -- the local preview's helmet
    w.engine.unit(0x301, HELMET_LUT) -- the remote player's preview helmet
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    Fake.show_ui(w.space, 3, {helmet = 0x0c0c0c0c, armor = 0x22222222, body = 0}, {[{0, 0}] = 0x301})
    w.frames(7) -- seen within 4 frames (the gate), then the job over two frames
    local preview = w.bound(0x300)[1]
    assert(preview ~= VANILLA[HELMET_LUT] and preview ~= avatar_texture.object, 'local preview recolored')
    for _, object in ipairs(w.bound(0x300)) do assert(object == preview, 'one texture for the preview pair') end
    assert(#w.engine.created == 1 + SPARES, 'the preview refilled a spare: no texture made, no wait')
    for _, object in ipairs(w.bound(0x301)) do assert(object == VANILLA[HELMET_LUT], 'remote preview untouched') end
    for _, object in ipairs(w.bound(0x100)) do assert(object == avatar_texture.object, 'the avatar keeps its own') end
    local seen = false
    for _, line in ipairs(w.lines) do
        if line:find('Preview recolored: 2 materials (helmet 0b0b0b0b', 1, true) and line:find('0 new textures;', 1, true)
            and line:find('longest frame %d+%.%d ms%)%.$') then
            seen = true
        end
    end
    assert(seen, 'logged, with the apply time, no new texture and the longest frame')
end)

-- Runs frames until no job is running (at most limit).
local function settle(w, limit)
    local n = 0
    repeat
        w.frame()
        n = n + 1
        assert(n < (limit or 200), 'a job did not end')
    until not w.instance.state.job
    return n
end

check('a preview job whose preview moved on is never applied (the audit, rank 4): a hover change ends it at its next '
      .. 'pause point, one job follows for what is shown; a closed preview gets none', function()
    local budget = Addon.BUDGET
    Addon.BUDGET = 0 -- one pause point a frame: the canned job spans 21 frames, as a new item's analysis spans dozens
    local w = setup({ui = true})
    settle(w)
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    while not (w.instance.state.request and w.instance.state.request.target == 'ui') do w.frame() end
    local first, count = w.instance.state.request, #requests
    w.frames(2)
    Fake.show_ui(w.space, 1, {helmet = 0x0c0c0c0c, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300}) -- hovered on
    local frames = settle(w)
    assert(first.obsolete and frames <= Addon.UI_GATE_FRAMES + 2, 'ended within a gate period: ' .. frames .. ' frames')
    assert(w.instance.ui_controller.applied == 0, 'the pair left behind never applied')
    settle(w) -- the job for what is shown now
    local last = requests[#requests]
    assert(#requests == count + 1 and last.target == 'ui' and last.helmet == 0x0c0c0c0c, 'one job, for the shown pair')
    assert(w.bound(0x300)[1] ~= VANILLA[HELMET_LUT] and w.instance.state.ui.applied == last, 'the shown pair applied')
    -- the preview closed while a job for it runs: nothing applied, no job follows
    Fake.show_ui(w.space, 1, {helmet = 0x0d0d0d0d, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    while not (w.instance.state.request and w.instance.state.request.helmet == 0x0d0d0d0d) do w.frame() end
    count = #requests
    Fake.show_ui(w.space, 1, nil)
    settle(w)
    w.frames(10)
    assert(#requests == count and w.instance.state.ui.applied.helmet == 0x0c0c0c0c, 'closed: nothing more')
    Addon.BUDGET = budget
end)

check('a pair the player left in the frames before its preview job ended is not applied: the preview is read again '
      .. 'first (the audit\'s scheduler proof: two stale bindings, then a second job)', function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    while not (w.instance.state.request and w.instance.state.request.target == 'ui') do w.frame() end
    Fake.show_ui(w.space, 1, {helmet = 0x0c0c0c0c, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x300})
    settle(w)
    assert(w.instance.ui_controller.applied == 0 and w.bound(0x300)[1] == VANILLA[HELMET_LUT], 'nothing stale bound')
    settle(w)
    local last = requests[#requests]
    assert(last.helmet == 0x0c0c0c0c and w.bound(0x300)[1] ~= VANILLA[HELMET_LUT], 'then the shown pair')
end)

check('an option set to the value it has starts no job and logs nothing (a menu re-sending it); a change does', function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local count, lines = #requests, #w.lines
    for _, o in ipairs({{'mode', Recolor.HELMET_FROM_ARMOR}, {'scheme', 0}, {'keep_sets', true}, {'recolor_cape', false}}) do
        w.instance.set_option(o[1], o[2])
    end
    w.frames(4)
    assert(#requests == count and #w.lines == lines, 'nothing: ' .. (#requests - count) .. ' jobs')
    w.instance.set_option('keep_sets', false)
    w.frames(3)
    assert(#requests == count + 1 and w.lines[lines + 1] == 'Option keep_sets = false.', 'a change: one job, logged')
end)

check('a new animation of the preview alone (its word after the unit refs) rebinds nothing (the audit, rank 13)',
      function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    w.frames(10)
    local count = #requests
    local animation = Fake.UI + 49160 + 160 + 132
    w.space.u32(animation, w.space.get32(animation) + 1)
    expect(w.frame(), {read_into = 2}, 'the frame after an animation change: avatar units and the preview record')
    assert(#requests == count, 'no job')
    w.engine.units[0x300].alive = false
    w.engine.unit(0x303, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x303}) -- a real new unit still rebinds at once
    w.frame()
    assert(w.bound(0x303)[1] ~= VANILLA[HELMET_LUT] and #requests == count, 'new units rebound without a job')
end)

check('Color Matching off with no paint scheme: idle frames read the units only (no body-copy slot, no UI preview), a '
      .. 'respawn starts no job; turning it on again recolors the preview shown meanwhile', function()
    local w = setup({ui = true, previews = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    w.frames(8)
    w.instance.set_option('mode', Recolor.OFF)
    settle(w)
    w.frames(4)
    assert(w.bound(0x100)[1] == VANILLA[HELMET_LUT] and w.bound(0x300)[1] == VANILLA[HELMET_LUT], 'both restored')
    local n = classify(w, 240, {read_into = 1}, {read_into = 1})
    assert(n.other == 2 and n.idle == 238, string.format('one read a frame but the two chain checks: %d other', n.other))
    local count = #requests
    w.engine.units[0x100].alive = false
    w.engine.unit(0x104, HELMET_LUT)
    w.space.u32(Fake.local_unit_at(0, 0), 0x104)
    w.frames(5)
    assert(#requests == count, 'a respawn with nothing to recolor: no job')
    w.engine.units[0x300].alive = false
    w.engine.unit(0x305, HELMET_LUT)
    Fake.show_ui(w.space, 1, {helmet = 0x0e0e0e0e, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x305}) -- unwatched
    w.frames(10)
    assert(#requests == count and w.bound(0x305)[1] == VANILLA[HELMET_LUT], 'nothing while off')
    w.instance.set_option('mode', Recolor.HELMET_FROM_ARMOR)
    settle(w)
    w.frames(Addon.UI_GATE_FRAMES)
    settle(w)
    assert(w.bound(0x104)[1] ~= VANILLA[HELMET_LUT], 'the avatar recolored again')
    assert(w.bound(0x305)[1] ~= VANILLA[HELMET_LUT] and requests[#requests].helmet == 0x0e0e0e0e,
           'the preview shown meanwhile recolored')
    -- off and on again with the preview unchanged: it was given back its colors, so it is recolored again
    w.instance.set_option('mode', Recolor.OFF)
    settle(w)
    w.frames(4)
    assert(w.bound(0x305)[1] == VANILLA[HELMET_LUT], 'off: the preview restored')
    w.instance.set_option('mode', Recolor.HELMET_FROM_ARMOR)
    settle(w)
    w.frames(Addon.UI_GATE_FRAMES)
    settle(w)
    assert(w.bound(0x305)[1] ~= VANILLA[HELMET_LUT], 'on again: the same preview recolored')
end)

check("a hover change re-plans the preview from the pool; closing it frees only the preview's textures", function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    w.frames(7)
    local first = w.bound(0x300)[1]
    w.engine.units[0x300].alive = false -- the game replaces the piece units on a hover change
    w.engine.unit(0x302, HELMET_LUT)
    Fake.show_ui(w.space, 1, {helmet = 0x0d0d0d0d, armor = 0x0ade6719, body = 0}, {[{0, 0}] = 0x302})
    local calls = {}
    for _ = 1, 3 do for k, v in pairs(w.frame()) do calls[k] = (calls[k] or 0) + v end end
    local second = w.bound(0x302)[1]
    assert(second ~= VANILLA[HELMET_LUT] and second ~= first, 'the new helmet recolored with another pooled texture')
    assert(not calls.create and calls.update == 1 and #w.engine.created == 1 + SPARES,
           'refilled, nothing made (no wait for the renderer): ' .. budget.describe(calls))
    w.frames(5)
    assert(w.instance.pool.free() == 1, "the previous pair's texture free after the retire delay")
    Fake.show_ui(w.space, 1, nil)
    w.frames(6)
    assert(w.instance.pool.free() == 2, 'the preview texture free once the preview closed')
    for _, object in ipairs(w.bound(0x100)) do assert(object == w.engine.created[1].object, 'the avatar keeps its own') end
    for _, texture in ipairs(w.engine.created) do assert(texture.alive, 'nothing destroyed') end
end)

check('the pool refills a free texture of the same size, makes spares in the frame it must make one, and keeps '
      .. 'at most POOL_MAX_FREE free per size', function()
    local w = setup()
    local pool = Engine.pool({native = w.engine.native, memory = w.memory})
    local function spec(width, height) return {width = width, height = height,
                                               data = ffi.new('float[?]', width * height * 4)} end
    local lut = spec(23, 8)
    local first = assert(pool.take(lut))
    assert(pool.made == 1 + SPARES and pool.free() == SPARES and first.data == lut.data, 'made with spares')
    local again = spec(23, 8)
    local second = assert(pool.take(again))
    assert(pool.made == 1 + SPARES and pool.refilled == 1, 'a spare refilled')
    assert(second.data == again.data and w.engine.created[second.handle].data == again.data,
           'the refilled texture holds its new data (the render thread reads it later)')
    local pattern = assert(pool.take(spec(3, 1)))
    assert(pattern.width == 3 and pool.made == 2 * (1 + SPARES), 'another size is never refilled from 23 x 8')
    local taken = {}
    for i = 1, Engine.POOL_MAX_FREE + 3 do taken[i] = assert(pool.take(spec(23, 8))) end
    local free = pool.free()
    for _, texture in ipairs(taken) do pool.give(texture) end
    local per_size = math.min(Engine.POOL_MAX_FREE, free - SPARES + #taken)
    assert(pool.free() == per_size + SPARES and pool.destroyed == free - SPARES + #taken - per_size,
           string.format('free %d, destroyed %d', pool.free(), pool.destroyed))
end)

check('a prepared plan\'s sizes are stocked ahead (pool.stock): POOL_STOCK free per LUT of a size, at most '
      .. 'POOL_MAX_FREE, a decal sheet copy only its count, every other LUT size of the game POOL_SPARES + 1; free ones '
      .. 'count, nothing made twice', function()
    local w = setup()
    local pool = Engine.pool({native = w.engine.native, memory = w.memory})
    local function spec(width, height)
        return {width = width, height = height, data = ffi.new('float[?]', width * height * 4)}
    end
    local luts, patterns = {}, {}
    for i = 1, 9 do luts['lut' .. i] = spec(23, 8) end -- an armor's nine
    luts.sheet = {sheet = true, width = 2048, height = 2048, mips = 12, size = 5592432, data = ffi.new('uint8_t[16]')}
    for i = 1, 2 do patterns['pattern' .. i] = spec(3, 1) end
    local made = pool.stock({luts = luts, patterns = patterns})
    local stock, others = Engine.POOL_STOCK, (#Engine.POOL_SIZES - 2) * (Engine.POOL_SPARES + 1)
    assert(made == Engine.POOL_MAX_FREE + 1 + 2 * stock + others and pool.made == made,
           string.format('9 x 23 x 8 capped at %d, one sheet, 2 x 3 x 1 times %d, %d of the other sizes: %d',
                         Engine.POOL_MAX_FREE, stock, others, made))
    for _, size in ipairs(Engine.POOL_SIZES) do
        local texture = assert(pool.take(spec(size[1], size[2])), 'a stocked ' .. size[1] .. ' x ' .. size[2])
        pool.give(texture)
    end
    assert(pool.made == made, 'every size of the game taken from the stock')
    assert(pool.stock({luts = luts, patterns = patterns}) == 0, 'stocked: nothing made again')
    local taken = assert(pool.take(luts.lut1))
    assert(taken and pool.made == made, 'taken from the stock')
    assert(pool.stock({luts = {one = spec(23, 8)}}) == 0, 'a smaller plan of a stocked size makes none')
end)

check('a plan that must grow the pool makes room for the next plan of its shape in the same frame: two 9-LUT armor plans '
      .. 'in a row grow once (v1.3: twice, a second 5-7 ms frame in the Armory); a helmet\'s plan makes 1 + 2 as before',
      function()
    local names, vanilla, units = {}, {}, {}
    for i = 1, 9 do
        names[i] = string.format('%016x', 0xa1000 + i)
        vanilla[names[i]] = 0x190100000 + i * 0x1000
        units[{i == 9 and 1 or 0, i == 9 and 2 or i + 1}] = 0x400 + i -- slots 2-9, and the undergarment of slot 2
    end
    local space = Fake.world({local_units = units})
    local engine = Fake.engine(space, vanilla)
    for i = 1, 9 do engine.unit(0x400 + i, names[i], 1) end
    local memory = Fake.memory(space)
    local pool = Engine.pool({native = engine.native, memory = memory})
    local controller = Recolor.controller({Engine = Engine, Avatar = Avatar, memory = memory, native = engine.native,
                                           pool = pool})
    local identity = assert(Avatar.resolve(memory, Fake.GAME))
    local pieces = {}
    for key in pairs(units) do
        pieces[#pieces + 1] = {piece = {type = key[1], slot = key[2], body = 0}, materials = {{}}, skin = false}
    end
    local target = {kit = {kit_type = 'Armor'}, pieces = pieces}
    local function plan(key)
        local luts = {}
        for i = 1, 9 do luts[names[i]] = lut_spec() end
        return {action = 'apply', key = key, luts = luts, patterns = {}, first = 1, last = 9, target = target}
    end
    assert(controller.apply(plan('armor A'), identity, nil, 1) == 9, 'nine materials bound')
    assert(pool.made == 18 and pool.free() == 9, string.format('made %d, free %d', pool.made, pool.free()))
    local made, created, refilled = pool.made, #engine.created, pool.refilled
    assert(controller.apply(plan('armor B'), identity, nil, 2) == 9, 'the next plan bound')
    assert(pool.made == made and #engine.created == created and pool.refilled - refilled == 9,
           'no texture made: nine refilled')
    for i = 1, 9 do
        assert(engine.binding(engine.units[0x400 + i].materials[1].material) ~= vanilla[names[i]], 'recolored ' .. i)
    end
    -- the retired plan's textures come back after the delay: free again for a third plan
    controller.collect(2 + Recolor.RETIRE_FRAMES)
    assert(pool.free() == 9, 'the first plan\'s nine free again: ' .. pool.free())
    -- a helmet's plan, one texture of its size: the needed one and POOL_SPARES spares, the first made bound
    local helmet_pool = Engine.pool({native = engine.native, memory = memory})
    local first = #engine.created
    local texture = helmet_pool.take(lut_spec()) -- without reserve, as v1.3
    assert(helmet_pool.made == 1 + SPARES and texture.handle == first + 1, 'take alone: as v1.3')
    local reserved = Engine.pool({native = engine.native, memory = memory})
    local spec = lut_spec()
    reserved.reserve(spec, 1)
    local taken = reserved.take(spec)
    assert(reserved.made == 1 + SPARES and taken.handle == first + 1 + SPARES + 1 and reserved.refilled == 0,
           'reserve then take: 1 + spares made, the first made taken with its own data, no refill')
end)

check('new analyses are saved by a sliced job after the last recolor and while the preview is closed, never on '
      .. 'the frame of a recolor', function()
    local w = setup({ui = true})
    local saves, frames_saving = 0, {}
    local reader = {dirty = true, reads = 0, close = function() end}
    function reader.save(yield) -- records every frame it runs in
        frames_saving[w.instance.state.frame] = true
        for _ = 1, 60 do
            if yield then yield() end
            frames_saving[w.instance.state.frame] = true
        end
        reader.dirty, saves = false, saves + 1
        return true
    end
    w.instance.state.holder.pipeline = reader
    w.frames(4) -- the avatar's job ends on frame 3 and is applied on frame 4
    assert(saves == 0 and w.instance.state.save_at == 4 + Addon.SAVE_DELAY_FRAMES, 'due later, not now')
    w.frames(Addon.SAVE_DELAY_FRAMES - 10)
    assert(saves == 0 and not next(frames_saving), 'nothing before the delay')
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    w.frames(2 * Addon.SAVE_DELAY_FRAMES) -- past the due frame its recolor set, the preview still shown
    assert(saves == 0 and not next(frames_saving), 'nothing while the preview is shown')
    Fake.show_ui(w.space, 1, nil)
    w.frames(Addon.SAVE_DELAY_FRAMES + 20)
    assert(saves == 1, 'saved once the preview was closed')
    local count = 0
    for _ in pairs(frames_saving) do count = count + 1 end
    assert(count > 1, 'the save spans frames: ' .. count)
    local line
    for _, l in ipairs(w.lines) do if l:find('Analysis cache saved (', 1, true) then line = l end end
    assert(line and tonumber(line:match('over (%d+) frames')) == count, 'logged: ' .. tostring(line))
    reader.dirty = true
    w.instance.state.save_at = w.instance.state.frame + 1
    w.instance.stopped('shutdown')
    assert(saves == 2 and w.lines[#w.lines - 1] == 'Analysis cache saved at shutdown.', 'saved at shutdown when due')
end)

check('UI preview cost: +1 read on 1 frame in 4 while it is not shown, +1 read per frame while it is (its record '
      .. 'and the occupied mask in one read)', function()
    local w = setup({ui = true})
    w.frames(5)
    local gates, others = 0, 0 -- others: the 30-frame material check and the 120-frame chain check add reads
    for _ = 1, 40 do
        local f = w.frame()
        local gate = w.instance.state.frame % Addon.UI_GATE_FRAMES == 0
        if gate then gates = gates + 1 end
        if not same(f, {read_into = gate and 2 or 1}) then others = others + 1 end
    end
    assert(gates == 10 and others <= 2, string.format('gate frames %d, other frames %d', gates, others))
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    w.frames(8)
    local shown = 0
    for _ = 1, 20 do if same(w.frame(), {read_into = 2}) then shown = shown + 1 end end
    assert(shown >= 18, 'avatar units, and the preview record and gate together, on ' .. shown .. ' of 20 frames')
end)

check('the apply reads a material\'s bindings once for all the slots the plan changes on it (the helmet\'s LUT and '
      .. 'pattern; before v1.4\'s performance pass they were read again for each slot: KB '
      .. 'match-your-colors-stress-test)', function()
    with_patterns = true
    local w = setup({patterns = true})
    local f, n = nil, 0
    repeat f, n = w.frame(), n + 1 until f.set_resource or n == 12
    with_patterns = false
    expect(f, {alive = 2, can_get = 2, commit = 1, create = 6, get = 2, material = 2, materials = 1, mesh = 1,
               meshes = 1, read_into = 33, resource = 6, set_resource = 4, time = 5}, 'the apply frame ' .. n)
end)

check('a planned pattern takes its own texture on the pattern slot, is checked every 30 frames and put back', function()
    with_patterns = true
    local w = setup({patterns = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    assert(#w.engine.created == 2 * (1 + SPARES), 'LUT and pattern textures and their spares, got ' .. #w.engine.created)
    local material = w.engine.units[0x100].materials[1].material
    local lut, pattern = w.engine.binding(material), w.engine.binding(material, Fake.PATTERN_SLOT)
    assert(lut ~= VANILLA[HELMET_LUT] and pattern ~= VANILLA[HELMET_PATTERN] and lut ~= pattern, 'both slots recolored')
    for _, object in ipairs(w.bound(0x200)) do assert(object == VANILLA[HELMET_LUT], 'remote helmet untouched') end
    local n = classify(w, 120, IDLE, CHECK)
    assert(n.check >= 3 and n.idle + n.check + n.other == 120, string.format('idle %d, check %d, other %d', n.idle,
           n.check, n.other))
    w.space.u64(w.engine.entry(material, Fake.PATTERN_SLOT) + 8, VANILLA[HELMET_PATTERN]) -- the game's own reset
    w.frames(63) -- two probes, checked in turn: each every 60 frames
    assert(w.engine.binding(material, Fake.PATTERN_SLOT) == pattern and #w.engine.created == 2 * (1 + SPARES),
           'the pattern recolored again with the same texture')
    w.instance.set_option('mode', Recolor.OFF)
    w.frames(3)
    assert(w.engine.binding(material) == VANILLA[HELMET_LUT]
           and w.engine.binding(material, Fake.PATTERN_SLOT) == VANILLA[HELMET_PATTERN], 'both slots back to vanilla')
    w.frames(4)
    for _, texture in ipairs(w.engine.created) do assert(texture.alive, 'textures kept') end
    assert(w.instance.pool.free() == 2 * (1 + SPARES), 'both textures free again')
    with_patterns = false
end)

check("the paint scheme reaches the avatar's and the preview's jobs; values out of range change nothing", function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    assert(requests[#requests].scheme == 0, 'no scheme by default')
    local texture = w.bound(0x100)[1]
    w.instance.set_option('scheme', 3)
    w.frames(3)
    local last = requests[#requests]
    assert(last.target == 'avatar' and last.scheme == 3 and last.mode == Recolor.HELMET_FROM_ARMOR, 'scheme 3 asked')
    assert(w.bound(0x100)[1] ~= texture and w.bound(0x100)[1] ~= VANILLA[HELMET_LUT], 'a new plan bound')
    local count = #requests
    for _, value in ipairs({#Schemes.LIST + 1, -1, 1.5, '3', true}) do w.instance.set_option('scheme', value) end
    w.frames(3)
    assert(#requests == count and w.instance.state.options.scheme == 3, 'out of range: ignored')
    w.instance.set_option('mode', Recolor.OFF)
    w.frames(3)
    last = requests[#requests]
    assert(last.mode == Recolor.OFF and last.scheme == 3 and w.bound(0x100)[1] ~= VANILLA[HELMET_LUT],
           'a scheme recolors with Color Matching off')
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, HOVERED, {[{0, 0}] = 0x300})
    w.frames(7)
    last = requests[#requests]
    assert(last.target == 'ui' and last.scheme == 3, 'the preview job carries the scheme')
    w.instance.set_option('scheme', 0)
    w.frames(12)
    assert(requests[#requests].scheme == 0 and w.bound(0x100)[1] == VANILLA[HELMET_LUT], 'scheme off, mode off')
end)

check('Recolor Cape: the cape takes the plan only with the option on, its tint (cape LUT slot) too; its kit is in the '
      .. 'request', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local function tints(unit)
        local out = {}
        for _, m in ipairs(w.engine.units[unit].materials) do
            out[#out + 1] = w.engine.binding(m.material, Fake.CAPE_LUT_SLOT)
        end
        return out
    end
    for _, object in ipairs(w.bound(0x106)) do assert(object == VANILLA[CAPE_LUT], 'the cape keeps its colors') end
    for _, object in ipairs(tints(0x106)) do assert(object == VANILLA[CAPE_TINT], 'and its tint') end
    local last = requests[#requests]
    assert(last.capes == false and last.cape == 0x72492837, 'the option off; the cape kit is known')
    w.instance.set_option('recolor_cape', true)
    w.frames(3)
    last = requests[#requests]
    assert(last.target == 'avatar' and last.capes == true and last.cape == 0x72492837, 'the cape asked for')
    local cape = w.bound(0x106)[1]
    assert(cape ~= VANILLA[CAPE_LUT], 'the cape recolored')
    for _, object in ipairs(tints(0x106)) do
        assert(object ~= VANILLA[CAPE_TINT] and object ~= cape, 'its tint bound to its own runtime texture')
    end
    for _, object in ipairs(w.bound(0x100)) do assert(object ~= VANILLA[HELMET_LUT], 'the helmet too') end
    w.frames(30) -- applies of the same plan (rebind checks) log no second report
    local reports = 0
    for _, line in ipairs(w.lines) do if line == 'Cape 72492837: canned report.' then reports = reports + 1 end end
    assert(reports == 1, 'the cape plan\'s report logged once: ' .. reports)
    w.instance.set_option('recolor_cape', false)
    w.frames(3)
    for _, object in ipairs(w.bound(0x106)) do assert(object == VANILLA[CAPE_LUT], 'off: the cape back') end
    for _, object in ipairs(tints(0x106)) do assert(object == VANILLA[CAPE_TINT], 'off: its tint back') end
    local n = classify(w, 120, IDLE, CHECK)
    assert(n.idle + n.check + n.other == 120 and n.check >= 3, 'idle frames as before')
end)

check('Recolor Cape: a recolored emblem\'s sheet (a BC3 copy with its mips) is bound on the cape\'s decal sheet slot '
      .. 'only, and put back with the plan', function()
    with_sheet = true
    local w = setup()
    -- the helmet's unit (slot 0, recolored with the cape) given a decal slot holding the sheet: never bound there
    local helmet = w.engine.unit(0x100, HELMET_LUT, nil, nil, nil, CAPE_SHEET)
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local function sheets(unit)
        local out = {}
        for _, m in ipairs(w.engine.units[unit].materials) do
            out[#out + 1] = w.engine.binding(m.material, Fake.DECAL_SLOT)
        end
        return out
    end
    for _, object in ipairs(sheets(0x106)) do assert(object == VANILLA[CAPE_SHEET], 'the sheet as it is') end
    w.instance.set_option('recolor_cape', true)
    w.frames(3)
    local bound = sheets(0x106)
    local made
    for _, t in pairs(w.engine.created) do
        if t.object == bound[1] then made = t end
    end
    assert(made and made.format == Fake.BC3 and made.mips == 12 and made.size == 5592432, 'a BC3 sheet with its mips')
    for _, object in ipairs(bound) do assert(object == made.object, 'every cape material: the copy') end
    assert(w.engine.binding(helmet[1].material, Fake.DECAL_SLOT) == VANILLA[CAPE_SHEET], 'the cape\'s unit only')
    w.instance.set_option('recolor_cape', false)
    w.frames(3)
    for _, object in ipairs(sheets(0x106)) do assert(object == VANILLA[CAPE_SHEET], 'off: the sheet back') end
    with_sheet = false
end)

check('another cape in the loadout: no job while Recolor Cape is off, the option then recolors the cape worn', function()
    local w = setup()
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    local count = #requests
    w.space.u32(Fake.CUSTOMIZATION + 2420, 0x03f9d46b) -- the Cover of Darkness
    w.frames(Addon.VERIFY_FRAMES + 1)
    assert(#requests == count, 'option off: another cape starts no job')
    w.instance.set_option('recolor_cape', true)
    w.frames(3)
    assert(#requests == count + 1 and requests[#requests].cape == 0x03f9d46b, 'on: the cape worn now')
    w.space.u32(Fake.CUSTOMIZATION + 2420, 0x72492837)
    w.frames(Addon.VERIFY_FRAMES + 1)
    assert(#requests == count + 2 and requests[#requests].cape == 0x72492837, 'on: another cape is a new job')
end)

check('Helmet and Armor Match Cape: another cape is a new job with Recolor Cape off, both items are recolored and the '
      .. 'cape keeps its colors; no cape gives the items back; the preview\'s cape counts too (user request 2026-10-09)',
      function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.instance.set_option('mode', Recolor.CAPE_SOURCE)
    w.frames(3)
    local last = requests[#requests]
    assert(last.target == 'avatar' and last.mode == Recolor.CAPE_SOURCE and not last.capes and last.cape == 0x72492837,
           'the cape worn asked for, Recolor Cape off')
    assert(w.bound(0x100)[1] ~= VANILLA[HELMET_LUT] and w.bound(0x101)[1] ~= VANILLA[ARMOR_LUT], 'both items recolored')
    for _, object in ipairs(w.bound(0x106)) do assert(object == VANILLA[CAPE_LUT], 'the cape keeps its colors') end
    -- per frame as a paint scheme (a world without the UI preview): idle frames read the units once, a check frame
    -- one probe; the cape adds no call
    local plain = setup()
    plain.frames(3)
    plain.instance.set_option('mode', Recolor.CAPE_SOURCE)
    plain.frames(4)
    assert(plain.instance.controller.probes == 2, 'helmet and armor textures tracked')
    local n = classify(plain, 120, IDLE, CHECK)
    assert(n.check >= 3 and n.idle + n.check + n.other == 120, string.format('idle %d, check %d, other %d', n.idle,
           n.check, n.other))
    local count = #requests
    w.space.u32(Fake.CUSTOMIZATION + 2420, 0x03f9d46b) -- the Cover of Darkness
    w.frames(Addon.VERIFY_FRAMES + 1)
    assert(#requests == count + 1 and requests[#requests].cape == 0x03f9d46b, 'another cape: a new job')
    w.space.u32(Fake.CUSTOMIZATION + 2420, 0)
    w.frames(Addon.VERIFY_FRAMES + 1)
    assert(requests[#requests].cape == 0 and w.bound(0x100)[1] == VANILLA[HELMET_LUT]
           and w.bound(0x101)[1] == VANILLA[ARMOR_LUT], 'no cape: the items given back')
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0, cape = 0x72492837}, {[{0, 0}] = 0x300})
    w.frames(7)
    count = #requests
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0, cape = 0x03f9d46b}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(#requests > count and requests[#requests].target == 'ui' and requests[#requests].cape == 0x03f9d46b,
           'another cape on the preview: a new preview job')
end)

check("the preview's cape counts only with Recolor Cape on", function()
    local w = setup({ui = true})
    w.frames(4) -- resolve, the job over two frames, its apply on the next
    w.engine.unit(0x300, HELMET_LUT)
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0, cape = 0x72492837}, {[{0, 0}] = 0x300})
    w.frames(7)
    local count = #requests
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0, cape = 0x03f9d46b}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(#requests == count, 'another cape on the preview: no job while the option is off')
    w.instance.set_option('recolor_cape', true)
    w.frames(7)
    local last = requests[#requests]
    assert(last.target == 'ui' and last.capes and last.cape == 0x03f9d46b, 'on: the preview job carries its cape')
    count = #requests
    Fake.show_ui(w.space, 1, {helmet = 0x0b0b0b0b, armor = 0x0ade6719, body = 0, cape = 0x72492837}, {[{0, 0}] = 0x300})
    w.frames(7)
    assert(#requests > count and requests[#requests].cape == 0x72492837, 'on: another cape is a new job')
end)

if rawget(_G, 'MYC_TEST_SETUP_ONLY') then return setup, requests, {same = same, classify = classify, records = RECORDS} end
print('PASS test_addon (' .. passed .. ' checks)')
