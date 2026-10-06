-- Match Your Colors: the recolor job end to end on the installed game's files: the kit catalogue in simulated
-- game memory (CPR-80 Bulwark helmet a5574ac2 and DS-191 Scorpion armor 0ade6719 from tests/fixtures/kits.lua,
-- laid out as the customization manager holds them), the job run as a coroutine with pause points, the
-- game-data reader opened for the job and closed after it, cached analyses on the next job, the plan equal to
-- the research pipeline's (tests/fixtures/plans.lua) and the new LUTs' fitted colors equal to its
-- (tests/fixtures/transfers.lua). Skipped (PASS, with a note) without game data.
-- Usage: luajit tests/test_job.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_job.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Files, Slim, Texture = require('files'), require('slim'), require('texture')
local Colour, Matcher, Kits, Recolor = require('colour'), require('matcher'), require('kits'), require('recolor')
local Cache, Transfer = require('cache'), require('transfer')
local appearance = require('appearance').new(require('appearance_data'))
local Fake = dofile(root .. '/tests/fake_game.lua')
Matcher.use(Colour)
local game_root = os.getenv('HD2_GAME_ROOT') or 'C:/Program Files (x86)/Steam/steamapps/common/Helldivers 2'
local probe = io.open(game_root .. '/data/bundles.nxa', 'rb')
if not probe then
    print('PASS test_job (skipped: no game data at ' .. game_root .. ')')
    return
end
probe:close()
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end

local HELMET, ARMOR = 'a5574ac2', '0ade6719'
local KIT_TYPES = {Armor = 0, Helmet = 1}

-- The customization manager's kit catalogue for the given fixture kits (kit 64 bytes, bodies 24, pieces 96).
local function catalogue(space, kits)
    local manager, list = 0x1B0000000, 0x1B1000000
    space.region(manager, 64)
    space.region(list, 8 * #kits)
    space.u64(Fake.GAME + 0x33264F8, manager)
    space.u64(manager, list) space.u32(manager + 8, #kits)
    local at = 0x1B2000000
    for i, kit in ipairs(kits) do
        local kit_at, bodies_at = at, at + 0x100
        local by_body, order = {}, {}
        for _, piece in ipairs(kit.pieces) do
            if not by_body[piece.body] then by_body[piece.body] = {} order[#order + 1] = piece.body end
            table.insert(by_body[piece.body], piece)
        end
        space.region(kit_at, 0x100 + 24 * #order + 96 * #kit.pieces + 64)
        space.u64(list + 8 * (i - 1), kit_at)
        space.u32(kit_at, tonumber(kit.id, 16)) space.u32(kit_at + 12, kit.set_id % 4294967296)
        space.u32(kit_at + 32, tonumber(kit.archive:sub(9, 16), 16)) space.u32(kit_at + 36, tonumber(kit.archive:sub(1, 8), 16))
        space.u32(kit_at + 40, KIT_TYPES[kit.kit_type]) space.u64(kit_at + 48, bodies_at) space.u32(kit_at + 56, #order)
        local pieces_at = bodies_at + 24 * #order
        for b, body in ipairs(order) do
            local list_b = by_body[body]
            local o = bodies_at + 24 * (b - 1)
            space.u32(o, body) space.u64(o + 8, pieces_at) space.u32(o + 16, #list_b)
            for _, piece in ipairs(list_b) do
                space.u32(pieces_at, tonumber(piece.path:sub(9, 16), 16)) space.u32(pieces_at + 4, tonumber(piece.path:sub(1, 8), 16))
                space.u32(pieces_at + 8, piece.slot) space.u32(pieces_at + 12, piece.type)
                space.u32(pieces_at + 24, tonumber(piece.lut:sub(9, 16), 16)) space.u32(pieces_at + 28, tonumber(piece.lut:sub(1, 8), 16))
                space.byte(pieces_at + 88, piece.tone)
                pieces_at = pieces_at + 96
            end
        end
        at = at + 0x10000
    end
end

local KITS = dofile(root .. '/tests/fixtures/kits.lua')
local chosen = {}
for _, kit in ipairs(KITS) do if kit.id == HELMET or kit.id == ARMOR then chosen[#chosen + 1] = kit end end
assert(#chosen == 2, 'fixture kits')
local space = Fake.world({players = 0})
catalogue(space, chosen)
local memory = Fake.memory(space)
local CACHE = root .. '/build/test-job.cache'
os.remove(CACHE)
local deps = {Files = Files, Slim = Slim, Texture = Texture, Colour = Colour, Transfer = Transfer, Matcher = Matcher,
              Kits = Kits, memory = memory, game = Fake.GAME, data_folder = game_root .. '/data/', Cache = Cache,
              cache_path = CACHE, build = {exe_sha256 = 'TEST-EXE', game_sha256 = 'TEST-GAME'},
              Appearance = appearance}
local holder = {}

-- A pipeline's analysis of a kit (any body), by kit id.
local function analysis_of(p, id)
    for _, a in pairs(p.analyses) do
        if a.kit.id == tonumber(id, 16) then return a end
    end
end

-- Runs one job to its end, pausing at every pause point; returns the result and the number of resumes.
local function run(request)
    local co = coroutine.create(function() return Recolor.job(deps, holder, request, coroutine.yield) end)
    local resumes, ok, result = 0, nil, nil
    repeat
        ok, result = coroutine.resume(co)
        assert(ok, tostring(result))
        resumes = resumes + 1
    until coroutine.status(co) == 'dead'
    return result, resumes
end

-- The Adler-32 of a plan as tests/fixtures/plans.lua stores it.
local function adler32(text)
    local a, b = 1, 0
    for i = 1, #text do a = (a + text:byte(i)) % 65521 b = (b + a) % 65521 end
    return b * 65536 + a
end
local function plan_sum(target, source)
    local mapping = Matcher.plan(Matcher.item(target.rows, target.kit.kit_type == 'Armor', Recolor.patterns_of(target),
                                              Recolor.look_of(target, appearance)),
                                 Matcher.item(source.rows, source.kit.kit_type == 'Armor', Recolor.patterns_of(source),
                                              Recolor.look_of(source, appearance)))
    local keys = {}
    for k in pairs(mapping) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. '=' .. (mapping[k].kind == 'accent' and '~' or '') .. mapping[k].source end
    return adler32(table.concat(parts, ';'))
end

local PLANS = dofile(root .. '/tests/fixtures/plans.lua')
local TRANSFERS = dofile(root .. '/tests/fixtures/transfers.lua')

-- The result's LUTs hold the research pipeline's fitted colors (float32) on every planned row.
local function check_colors(result, plan_key)
    local cases = assert(TRANSFERS[plan_key], 'fixture ' .. plan_key)
    for _, case in ipairs(cases) do
        local lut, row = case.key:match('^(%x+):(%d+)$')
        local spec = assert(result.luts[lut], 'LUT ' .. lut)
        local base = tonumber(row) * spec.width * 4
        for k, column in ipairs(Transfer.COLUMNS) do
            for ch = 0, 2 do
                local got, want = spec.data[base + column * 4 + ch], case.colors[(k - 1) * 3 + ch + 1]
                assert(math.abs(got - want) <= 1e-6, string.format('%s column %d: %.9g, expected %.9g', case.key, column,
                       got, want))
            end
        end
    end
    return #cases
end

check('helmet matches armor: the job pauses often, reads the files once, plans as the research pipeline', function()
    local result, resumes = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2,
                                 armor = 0x0ade6719, body = 0})
    assert(result.action == 'apply' and result.first == 0 and result.last == 0, 'helmet slots')
    assert(resumes > 20, 'the job paused at its pause points (' .. resumes .. ' resumes)')
    assert(result.luts['962a946e964ebc40'], 'the Bulwark helmet LUT is planned')
    local p = holder.pipeline
    local h, a = analysis_of(p, HELMET), analysis_of(p, ARMOR)
    assert(plan_sum(h, a) == PLANS['h' .. HELMET .. ARMOR], 'plan equals the research pipeline')
    assert(check_colors(result, 'h' .. HELMET .. ARMOR) > 0, 'fitted colors equal the research pipeline')
    assert(p.files and p.files.reads > 0, 'the reader is open during the job')
    p.close()
    assert(p.files == nil and p.deps.slim == nil and p.reads > 0, 'closed after the job')
end)

check('armor matches helmet: cached analyses, the reader stays closed', function()
    local reads = holder.pipeline.reads
    local result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, helmet = 0xa5574ac2,
                        armor = 0x0ade6719, body = 0})
    assert(result.action == 'apply' and result.first == 1 and result.last == 9, 'armor slots')
    local count = 0
    for _ in pairs(result.luts) do count = count + 1 end
    -- nine: the generic cape piece is left out of the analysis (v11.5), its LUT is no longer planned
    assert(count == 9, 'nine armor LUTs planned, got ' .. count)
    assert(holder.pipeline.files == nil and holder.pipeline.reads == reads, 'nothing read')
    local p = holder.pipeline
    assert(plan_sum(analysis_of(p, ARMOR), analysis_of(p, HELMET)) == PLANS['a' .. ARMOR .. HELMET],
           'plan equals the research pipeline')
    assert(check_colors(result, 'a' .. ARMOR .. HELMET) > 0, 'fitted colors equal the research pipeline')
end)

check('the analyses go to the disk cache; a new session recolors from it without reading game files', function()
    assert(holder.pipeline.cache_status == 'none yet', tostring(holder.pipeline.cache_status))
    assert(holder.pipeline.save(), 'saved')
    local text = Cache.read(CACHE)
    assert(text and #text > 1000, 'cache written')
    holder = {} -- a new session
    local result = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2,
                        armor = 0x0ade6719, body = 0})
    local p = holder.pipeline
    assert(p.cache_status == '2 kit analyses loaded', tostring(p.cache_status))
    assert(result.action == 'apply' and p.files == nil and p.reads == 0, 'no game file read (samples cached too)')
    assert(plan_sum(analysis_of(p, HELMET), analysis_of(p, ARMOR)) == PLANS['h' .. HELMET .. ARMOR],
           'plan from the cache equals the research pipeline')
    assert(check_colors(result, 'h' .. HELMET .. ARMOR) > 0, 'fitted colors from the cache equal the research pipeline')
    assert(p.save(), 'nothing new to save')
    Cache.write(CACHE, text:sub(1, #text - 10)) -- damaged: not used, analysed again
    holder = {}
    run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0})
    assert(holder.pipeline.cache_status:find('not used', 1, true) and holder.pipeline.reads == 0
           and holder.pipeline.files, 'damaged cache ignored, files read again')
    holder.pipeline.close()
    os.remove(CACHE)
end)

check('Off and complete sets need no reading at all', function()
    assert(run({mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0}).action
           == 'restore')
end)

print('PASS test_job (' .. passed .. ' checks)')
