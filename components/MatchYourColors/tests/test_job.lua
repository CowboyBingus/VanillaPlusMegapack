-- Match Your Colors: the recolor job end to end on the installed game's files: the kit catalogue in simulated
-- game memory (CPR-80 Bulwark helmet a5574ac2 and DS-191 Scorpion armor 0ade6719, and for the hood option the
-- RS-100 Sanctioner helmet 47bcec20 and CE-35 Trench Engineer armor fb4b1254, from tests/fixtures/kits.lua,
-- laid out as the customization manager holds them), the job run as a coroutine with pause points, the
-- game-data reader opened for the job and closed after it, cached analyses on the next job, the plan equal to
-- the research pipeline's (tests/fixtures/plans.lua) and the new LUTs' fitted colors equal to its
-- (tests/fixtures/transfers.lua, material_transfers.lua); a paint scheme read from the game's bundles on both items;
-- and a mod's LUT patch read instead of the archived LUT (src/patches.lua). The installed mods' patches are not
-- read: the jobs see an empty patch folder (build/test-job-patches/), or one with a test patch. Skipped (PASS, with
-- a note) without game data.
-- Usage: luajit tests/test_job.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_job.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
local ffi = require('ffi')
local Files, Slim, Texture = require('files'), require('slim'), require('texture')
local Colour, Matcher, Kits, Recolor = require('colour'), require('matcher'), require('kits'), require('recolor')
local Cache, Transfer, Patches, Schemes = require('cache'), require('transfer'), require('patches'), require('schemes')
local Capes = require('capes')
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
local KIT_TYPES = {Armor = 0, Helmet = 1, Cape = 2}

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
                for _, f in ipairs({{'cape_lut', 40}, {'gradient', 48}, {'fields', 64}, {'decal', 80}}) do -- a cape's tint, fields, sheet
                    local value = piece[f[1]]
                    if value then
                        space.u32(pieces_at + f[2], tonumber(value:sub(9, 16), 16))
                        space.u32(pieces_at + f[2] + 4, tonumber(value:sub(1, 8), 16))
                    end
                end
                space.byte(pieces_at + 88, piece.tone)
                pieces_at = pieces_at + 96
            end
        end
        at = at + 0x10000
    end
end

local HOODED, TRENCH = '47bcec20', 'fb4b1254'
local SET_HELMET, SET_ARMOR = '7934ed8b', '1f9bfa78' -- the FS-37 Ravager set
local COVER_OF_DARKNESS = '03f9d46b'
local UNITED = '6d9b8e21' -- United in Equality: a purple tint in its cape LUT (user report 2026-10-07)
local KITS = dofile(root .. '/tests/fixtures/kits.lua')
local CAPES = dofile(root .. '/tests/fixtures/capes.lua')
local WINTER_WARRIOR, HAZ_MASTER = 'cd3d20dc', 'e9add047' -- the user's outfit with United in Equality (2026-10-07)
-- the B-01 Tactical set with the Drape of Glory: its dark grey emblem vanished on the cloth (user, image review
-- 2026-10-07)
local B01_HELMET, B01_ARMOR, DRAPE = '261c4a52', '4f7fb2bd', '9a864667'
local chosen = {}
for _, kit in ipairs(KITS) do
    if kit.id == HELMET or kit.id == ARMOR or kit.id == HOODED or kit.id == TRENCH or kit.id == SET_HELMET
        or kit.id == SET_ARMOR or kit.id == WINTER_WARRIOR or kit.id == HAZ_MASTER or kit.id == B01_HELMET
        or kit.id == B01_ARMOR then
        chosen[#chosen + 1] = kit
    end
end
local cover, united, drape
for _, kit in ipairs(CAPES) do
    if kit.id == COVER_OF_DARKNESS then cover = kit end
    if kit.id == UNITED then united = kit end
    if kit.id == DRAPE then drape = kit end
end
chosen[#chosen + 1] = cover
chosen[#chosen + 1] = united
chosen[#chosen + 1] = drape
assert(#chosen == 13 and cover and united and drape, 'fixture kits')
local space = Fake.world({players = 0})
catalogue(space, chosen)
local memory = Fake.memory(space)
local CACHE = root .. '/build/test-job.cache'
os.remove(CACHE)
-- The patch folder the jobs see: empty, unless a check writes a test patch into it.
local PATCHES = root .. '/build/test-job-patches/'
local function clear_patches()
    local probe = io.open(PATCHES .. 'probe', 'wb')
    if not probe then
        os.execute('mkdir "' .. PATCHES:gsub('/', '\\') .. '"') -- lint-ok: R5 test process only
        probe = assert(io.open(PATCHES .. 'probe', 'wb'), 'cannot write ' .. PATCHES)
    end
    probe:close()
    for _, name in ipairs(Files.new(PATCHES).list('*')) do os.remove(PATCHES .. name) end
end
clear_patches()
local deps = {Files = Files, Slim = Slim, Patches = Patches, Texture = Texture, Colour = Colour, Transfer = Transfer,
              Matcher = Matcher, Kits = Kits, Schemes = Schemes, Capes = Capes, memory = memory, game = Fake.GAME,
              data_folder = game_root .. '/data/', patch_folder = PATCHES, Cache = Cache, cache_path = CACHE,
              build = {exe_sha256 = 'TEST-EXE', game_sha256 = 'TEST-GAME'}, Appearance = appearance,
              wait = coroutine.yield} -- the addon's: game files read through overlapped handles (src/files.lua)
local holder = {}

-- A pipeline's analysis of a kit (any body), by kit id.
local function analysis_of(p, id)
    for _, a in pairs(p.analyses) do
        if a.kit.id == tonumber(id, 16) then return a end
    end
end

-- Runs one job to its end, pausing at every pause point; returns the result and the number of resumes. Every pause
-- names its stage: the addon logs a job's longest slice with it (the first job's first slices, which build the
-- pipeline, logged 'in nil' in a v1.3 release smoke, 2026-10-07).
local function run(request)
    local co = coroutine.create(function() return Recolor.job(deps, holder, request, coroutine.yield) end)
    local resumes, ok, result = 0, nil, nil
    repeat
        ok, result = coroutine.resume(co)
        assert(ok, tostring(result))
        assert(coroutine.status(co) == 'dead' or type(holder.stage) == 'string', 'a pause without a stage')
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
local MATERIAL_TRANSFERS = dofile(root .. '/tests/fixtures/material_transfers.lua')

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

check('Match Materials: the Bulwark\'s metal shell takes the Scorpion\'s paint finish and the reference colors', function()
    holder = {}
    local base = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0}
    local plain = run(base)
    local request = {materials = true}
    for k, v in pairs(base) do request[k] = v end
    local result = run(request)
    assert(result.action == 'apply' and result.key ~= plain.key, 'its own plan (cache key)')
    local cases = assert(MATERIAL_TRANSFERS['h' .. HELMET .. ARMOR], 'the test pair paints rows')
    local p = holder.pipeline
    local source = analysis_of(p, ARMOR)
    for _, case in ipairs(cases) do
        local lut, row = case.key:match('^(%x+):(%d+)$')
        local slut, srow = case.finish:match('^(%x+):(%d+)$')
        local spec, from = result.luts[lut], source.luts[slut]
        local t, s = tonumber(row) * spec.width * 4, tonumber(srow) * from.width * 4
        assert(spec.data[t + 27] == math.min(math.max(from.values[s + 27], 0), 1), case.key .. ' metallic')
        for i = 28, 31 do assert(spec.data[t + i] == 0, case.key .. ' no detail metallic controls') end
        for i = 32, 35 do assert(spec.data[t + i] == from.values[s + i], case.key .. ' specular') end
        assert(spec.data[t + 40] == from.values[s + 40], case.key .. ' roughness')
        for k, column in ipairs(Transfer.COLUMNS) do
            for ch = 0, 2 do
                local got, want = spec.data[t + column * 4 + ch], case.colors[(k - 1) * 3 + ch + 1]
                assert(math.abs(got - want) <= 1e-6, string.format('%s column %d: %.9g, expected %.9g', case.key,
                       column, got, want))
            end
        end
    end
    local hoods = {keep_hoods = true}
    for k, v in pairs(base) do hoods[k] = v end
    local kept = run(hoods) -- the Bulwark has no hood: the same colors under its own key
    assert(kept.key ~= plain.key, 'its own plan (cache key)')
    for lut, spec in pairs(plain.luts) do
        for i = 0, spec.width * spec.height * 4 - 1 do
            assert(kept.luts[lut].data[i] == spec.data[i], 'no hood rows: unchanged, ' .. lut .. ' value ' .. i)
        end
    end
    p.close()
end)

check('Recolor Hoods off: the RS-100 Sanctioner\'s hood rows keep their vanilla values, its mask is recolored', function()
    local HOOD_LUT = '2d079ad2f41684e1' -- rows 0 and 1: the hood; 2 and 3: the mask
    local base = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0x47bcec20, armor = 0xfb4b1254, body = 0}
    local on = run(base)
    local request = {keep_hoods = true}
    for k, v in pairs(base) do request[k] = v end
    local off = run(request)
    local vanilla = analysis_of(holder.pipeline, HOODED).luts[HOOD_LUT]
    local function changed(result, row)
        local spec, t = result.luts[HOOD_LUT], row * vanilla.width * 4
        for i = 0, vanilla.width * 4 - 1 do
            if spec.data[t + i] ~= vanilla.values[t + i] then return true end
        end
        return false
    end
    assert(changed(on, 0) and changed(on, 1) and changed(on, 2), 'hoods recolored: hood and mask change')
    assert(not changed(off, 0) and not changed(off, 1), 'hoods kept: the hood rows stay vanilla')
    assert(changed(off, 2) and changed(off, 3), 'hoods kept: the mask still takes the armor\'s color')
    assert(plan_sum(analysis_of(holder.pipeline, HOODED), analysis_of(holder.pipeline, TRENCH))
           == PLANS['h' .. HOODED .. TRENCH], 'the default plan still equals the research pipeline')
    holder.pipeline.close()
end)

-- The plan of a cape against a source (its design zones kept readable, as the job plans it), hashed as
-- tests/fixtures/capes.lua hashes it.
local function cape_plan_sum(cape, source)
    local t = Matcher.item(cape.rows, false, Recolor.patterns_of(cape), Recolor.look_of(cape, appearance))
    local s = Matcher.item(source.rows, source.kit.kit_type == 'Armor', Recolor.patterns_of(source),
                           Recolor.look_of(source, appearance))
    local mapping = Matcher.plan(t, s)
    if cape.zones then Matcher.cape_zones(mapping, t, s, cape.zones, cape.tint_of) end
    local keys = {}
    for k in pairs(mapping) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = k .. '=' .. (mapping[k].kind == 'accent' and '~' or '') .. mapping[k].source end
    return adler32(table.concat(parts, ';'))
end
local function expected_cape_plan(source_id)
    for _, pair in ipairs(cover.plans) do if pair[1] == source_id then return pair[2] end end
end

check('Recolor Cape: the Cover of Darkness takes the armor\'s colors with the helmet, as the reference plans', function()
    holder = {}
    local base = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0}
    local plain = run(base)
    local request = {capes = true, cape = tonumber(COVER_OF_DARKNESS, 16)}
    for k, v in pairs(base) do request[k] = v end
    local result = run(request)
    local CAPE_LUT = cover.pieces[1].lut
    assert(result.action == 'apply' and result.luts[CAPE_LUT] and result.luts['962a946e964ebc40'], 'helmet and cape')
    assert(result.first == 0 and result.last == 1 and #result.targets == 2, 'slots 0-1: the helmet and the cape')
    assert(result.key ~= plain.key and not plain.luts[CAPE_LUT], 'without the option the cape keeps its colors')
    local p = holder.pipeline
    local cape = analysis_of(p, COVER_OF_DARKNESS)
    assert(cape and cape.kit.kit_type == 'Cape' and #cape.rows == #cover.rows, 'the cape analysed')
    assert(cape_plan_sum(cape, analysis_of(p, ARMOR)) == expected_cape_plan(ARMOR), 'plan equals the reference')
    local red = cape.luts[CAPE_LUT]
    local changed = false
    for i = 0, 3 do
        if result.luts[CAPE_LUT].data[4 * red.width * 4 + i] ~= red.values[4 * red.width * 4 + i] then changed = true end
    end
    assert(changed, 'the red inside (row 4) takes another color')
    local armor = {mode = Recolor.ARMOR_FROM_HELMET}
    for k, v in pairs(request) do if armor[k] == nil then armor[k] = v end end
    local reverse = run(armor)
    assert(reverse.first == 1 and reverse.last == 9 and reverse.luts[CAPE_LUT], 'armor matches helmet: the cape too')
    assert(cape_plan_sum(cape, analysis_of(p, HELMET)) == expected_cape_plan(HELMET), 'against the helmet')
    p.close()
end)

check('Recolor Cape: United in Equality with the user\'s outfit: its tint refitted in a copy of its cape LUT (column 3 '
      .. 'RGB only), its emblem recolored to stay readable, one report line; the cache entry keeps tint and zones',
      function()
    holder = {}
    local request = {mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, helmet = tonumber(WINTER_WARRIOR, 16),
                     armor = tonumber(HAZ_MASTER, 16), body = 0, materials = true, capes = true,
                     cape = tonumber(UNITED, 16)}
    local result = run(request)
    local piece = united.pieces[1]
    local spec = assert(result.luts[piece.cape_lut], 'the cape LUT in the result')
    assert(spec.cape and spec.width == 16 and spec.height == 1 and result.luts[piece.lut], 'a cape LUT copy and the LUT')
    local p = holder.pipeline
    local made = assert(p.plans[result.key], 'the cape plan kept')
    assert(made.zones and made.zones.picked == 1 and made.zones.lost == 0, 'the emblem zone took a source color')
    assert(result.cape_report and result.cape_report:find('1 recolored to stay readable', 1, true)
           and result.cape_report:find('tint 24%', 1, true), 'the report: ' .. tostring(result.cape_report))
    local cape = analysis_of(p, UNITED)
    assert(cape.tint_of and cape.tint_of[piece.cape_lut] == piece.lut and cape.zones and cape.zones[2], 'tint and zones')
    local vanilla = cape.luts[piece.cape_lut].values
    for i = 0, 63 do
        if i < 12 or i > 14 then assert(spec.data[i] == vanilla[i], 'cape LUT value ' .. i .. ' kept') end
    end
    assert(spec.data[12] ~= vanilla[12] or spec.data[13] ~= vanilla[13], 'the tint (column 3) recolored')
    assert(p.save(), 'saved')
    p.close()
    holder = {} -- a new session reads the analysis from the cache
    local again = run(request)
    local cached = analysis_of(holder.pipeline, UNITED)
    assert(cached.cached and cached.tint_of[piece.cape_lut] == piece.lut and cached.zones[2], 'from the cache')
    for i = 0, 63 do assert(again.luts[piece.cape_lut].data[i] == spec.data[i], 'the same tint: ' .. i) end
    holder.pipeline.close()
end)

check('Recolor Cape: the Drape of Glory on the B-01 Tactical set: its emblem, a dark grey sheet mark, is recolored in a '
      .. 'copy of its decal sheet (BC3, every mip), the rest of the sheet kept; the cache keeps the emblem', function()
    holder = {}
    local request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                     armor = tonumber(B01_ARMOR, 16), body = 0, capes = true, cape = tonumber(DRAPE, 16)}
    local result = run(request)
    local piece = drape.pieces[1]
    local sheet = assert(result.luts[piece.decal], 'the sheet in the result')
    assert(sheet.sheet and sheet.width == 2048 and sheet.height == 2048 and sheet.mips == 12 and sheet.size == 5592432,
           'a BC3 copy of the 2048 x 2048 sheet with its 12 mips')
    assert(result.first == 1 and result.last == 1 and result.luts[piece.lut], 'only the cape (the set kept)')
    local p = holder.pipeline
    local cape = analysis_of(p, DRAPE)
    assert(#cape.emblems == 1 and cape.emblems[1].row == 0 and cape.emblems[1].L < 30, 'one dark emblem on row 0')
    local made = assert(p.plans[result.key], 'the cape plan kept')
    assert(made.emblems and made.emblems.picked == 1 and made.sheet and #made.sheet.cells == 1, 'the emblem picked')
    assert(made.luts[piece.decal] == nil, 'the plan keeps the recipe only (a sheet is 5.6 MB)')
    assert(result.cape_report:find('emblems: 1 recolored to stay readable', 1, true), 'the report: ' .. result.cape_report)
    local original = p.sheet(made.sheet, drape.archive)
    local rect, changed, outside = made.sheet.cells[1].rect, 0, 0
    for at = 0, sheet.size - 1, 16 do -- mip 0 blocks: inside the cell some endpoints change, outside none
        if at < 2048 * 2048 then
            local bx, by = (at / 16) % 512, math.floor(at / 16 / 512)
            local inside = bx * 4 + 3 >= rect[1] and bx * 4 < rect[3] and by * 4 + 3 >= rect[2] and by * 4 < rect[4]
            for k = 0, 15 do
                if sheet.data[at + k] ~= original[at + k] then
                    if inside then changed = changed + 1 else outside = outside + 1 end
                    assert(k >= 8 and k <= 11, 'only color endpoints change')
                end
            end
        end
    end
    assert(changed > 1000 and outside == 0, 'the emblem cell recolored, the rest kept: ' .. changed .. ', ' .. outside)
    local again = run(request) -- the same recipe: the kept sheet
    assert(again.luts[piece.decal] == sheet, 'the kept sheet reused')
    assert(p.save(), 'saved')
    p.close()
    holder = {}
    local cached_run = run(request)
    local cached = analysis_of(holder.pipeline, DRAPE)
    assert(cached.cached and #cached.emblems == 1 and cached.emblems[1].L == cape.emblems[1].L, 'the emblem from the cache')
    assert(cached_run.luts[piece.decal] == sheet, 'the same recipe from the cached analysis')
    holder.pipeline.close()
end)

check('Recolor Cape: a complete set keeps its colors and gives them to its cape; a scheme paints the cape too', function()
    holder = {}
    local set = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = tonumber(SET_HELMET, 16),
                 armor = tonumber(SET_ARMOR, 16), body = 0}
    assert(run(set).action == 'restore', 'the FS-37 Ravager set stays as it is')
    local with_cape = {capes = true, cape = tonumber(COVER_OF_DARKNESS, 16)}
    for k, v in pairs(set) do with_cape[k] = v end
    local result = run(with_cape)
    local CAPE_LUT = cover.pieces[1].lut
    local count = 0
    for _ in pairs(result.luts) do count = count + 1 end
    assert(result.action == 'apply' and result.first == 1 and result.last == 1 and count == 1 and result.luts[CAPE_LUT],
           'only the cape, slot 1')
    local scheme = {scheme = 3}
    for k, v in pairs(with_cape) do scheme[k] = v end
    local painted = run(scheme)
    assert(painted.first == 0 and painted.last == 9 and painted.luts[CAPE_LUT] and #painted.targets == 3,
           'helmet, armor and cape')
    holder.pipeline.close()
end)

check('Off and complete sets need no reading at all', function()
    assert(run({mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0}).action
           == 'restore')
end)

check('a paint scheme recolors both items from its LUT in the game\'s bundles; camo rows copy its camo', function()
    holder = {}
    local base = {mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0}
    local solid = {scheme = 1}
    for k, v in pairs(base) do solid[k] = v end
    local result = run(solid)
    assert(result.action == 'apply' and result.first == 0 and result.last == 9 and #result.targets == 2,
           'both items, every slot, with Color Matching off')
    assert(result.luts['962a946e964ebc40'], 'the Bulwark helmet LUT is planned')
    local p = holder.pipeline
    local armor_luts = 0
    for name in pairs(analysis_of(p, ARMOR).luts) do if result.luts[name] then armor_luts = armor_luts + 1 end end
    assert(armor_luts > 0, 'armor LUTs planned too')
    local camo_scheme = Schemes.LIST[3] -- Forest Camo: its camo row (r1) is the primary
    local camo = {scheme = 3}
    for k, v in pairs(base) do camo[k] = v end
    result = run(camo)
    local lut = assert(p.schemes[camo_scheme.lut], 'the scheme LUT read once and kept')
    local source = (camo_scheme.camo and 1 or 0) * lut.width * 4
    local copied = 0
    for _, spec in pairs(result.luts) do
        if spec.width == 23 then
            for r = 0, spec.height - 1 do
                local t, same = r * spec.width * 4, true
                for _, column in ipairs({16, 17, 18, 19, 21}) do
                    for ch = 0, 3 do
                        if spec.data[t + column * 4 + ch] ~= lut.values[source + column * 4 + ch] then same = false end
                    end
                end
                if same then copied = copied + 1 end
            end
        end
    end
    assert(copied > 0, 'rows taking the camo row carry its camo columns')
    p.close()
end)

-- A patch file (classic archive) in PATCHES holding one texture: main and GPU parts as Lua strings.
local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
                                          math.floor(v / 16777216) % 256) end
local function le64(hex) return le32(tonumber(hex:sub(9, 16), 16)) .. le32(tonumber(hex:sub(1, 8), 16)) end
local function write_texture_patch(file, name, main, gpu)
    local base = 72 + 32
    local toc = le64(name) .. le64(Kits.TYPE_TEXTURE) .. le32(base + 80) .. le32(0) .. string.rep('\0', 8)
        .. string.rep('\0', 8) .. string.rep('\0', 16) .. le32(#main) .. le32(0) .. le32(#gpu) .. string.rep('\0', 12)
    local out = assert(io.open(PATCHES .. file, 'wb'))
    out:write(le32(0xF0000011), le32(1), le32(1), string.rep('\0', 60), string.rep('\0', 32), toc, main)
    out:close()
    out = assert(io.open(PATCHES .. file .. '.gpu_resources', 'wb'))
    out:write(gpu)
    out:close()
    out = assert(io.open(PATCHES .. file .. '.stream', 'wb'))
    out:close()
end

check('a mod\'s LUT patch is read instead of the archived LUT and keys the cache apart (user report 2026-10-06)',
      function()
    local LUT = '962a946e964ebc40' -- the CPR-80 Bulwark helmet's
    holder = {}
    local request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719,
                     body = 0}
    run(request)
    local vanilla_header = holder.pipeline.header
    local vanilla = analysis_of(holder.pipeline, HELMET)
    local largest
    for _, row in ipairs(vanilla.rows) do
        if row.lut == LUT and not Matcher.light(row) and (not largest or row.area > largest.area) then largest = row end
    end
    assert(largest and largest.a < 30, 'a paint row of the helmet LUT, not red yet')
    holder.pipeline.close()
    -- the mod: the archived LUT with that row's base color made red (R16G16B16A16_FLOAT: 1, 0, 0)
    local slim = Slim.open(Files.new(game_root .. '/data/'), '')
    local kit
    for _, k in ipairs(chosen) do if k.id == HELMET then kit = k end end
    local record = assert(slim.locate(kit.archive, LUT, Kits.TYPE_TEXTURE), 'the archived LUT')
    local function part(name)
        local size = slim.part_size(record, name)
        local out = ffi.new('uint8_t[?]', math.max(size, 1))
        if size > 0 then slim.part(kit.archive, record, name, 0, size, out, 0) end
        return ffi.string(out, size)
    end
    local main, gpu = part('main'), part('gpu')
    slim.close()
    assert(#gpu >= 23 * 8 * 8, 'mip 0 in the GPU part')
    local at = largest.row * 23 * 8
    gpu = gpu:sub(1, at) .. '\0\60\0\0\0\0' .. gpu:sub(at + 7)
    write_texture_patch('9ba626afa44a3aa3.patch_0', LUT, main, gpu)
    deps.cache_path = root .. '/build/test-job-modded.cache'
    os.remove(deps.cache_path)
    holder = {}
    local result = run(request)
    local p = holder.pipeline
    local modded = analysis_of(p, HELMET)
    local row
    for _, r in ipairs(modded.rows) do if r.key == largest.key then row = r end end
    assert(row and row.a > largest.a + 30, string.format('the analysis reads the mod: red, a %.1f (vanilla %.1f)',
           row and row.a or 0, largest.a))
    assert(p.patch_status:find('1 patch files hold 1 ', 1, true), tostring(p.patch_status))
    assert(p.header ~= vanilla_header, 'the cache header names the installed mods')
    local values = modded.luts[LUT].values
    assert(values[largest.row * 23 * 4] == 1 and values[largest.row * 23 * 4 + 1] == 0, 'the LUT values are the mod\'s')
    assert(result.action == 'apply' and result.luts[LUT], 'recolored from the modded LUT')
    p.close()
    os.remove(deps.cache_path)
    deps.cache_path = CACHE
    clear_patches()
end)

-- The archived LUT of the CPR-80 Bulwark helmet (main and GPU parts) and its largest paint row.
local function bulwark_lut()
    local LUT = '962a946e964ebc40'
    local slim = Slim.open(Files.new(game_root .. '/data/'), '')
    local kit
    for _, k in ipairs(chosen) do if k.id == HELMET then kit = k end end
    local record = assert(slim.locate(kit.archive, LUT, Kits.TYPE_TEXTURE), 'the archived LUT')
    local function part(name)
        local size = slim.part_size(record, name)
        local out = ffi.new('uint8_t[?]', math.max(size, 1))
        if size > 0 then slim.part(kit.archive, record, name, 0, size, out, 0) end
        return ffi.string(out, size)
    end
    local main, gpu = part('main'), part('gpu')
    slim.close()
    return LUT, main, gpu
end

-- gpu with 6 bytes (three halves) replaced at LUT row r, column c (mip 0, 23 x 8 R16G16B16A16_FLOAT), channel ch.
local function poke(gpu, r, c, ch, bytes)
    local at = (r * 23 + c) * 8 + ch * 2
    return gpu:sub(1, at) .. bytes .. gpu:sub(at + #bytes + 1)
end

check('a mod\'s LUT row: a color change keeps its measured response, a finish change drops it; a cached analysis is '
      .. 'checked against the patch\'s content (review 2026-10-06)', function()
    local LUT, main, gpu = bulwark_lut()
    local request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719,
                     body = 0}
    holder = {}
    run(request)
    local largest
    for _, row in ipairs(analysis_of(holder.pipeline, HELMET).rows) do
        if row.lut == LUT and not Matcher.light(row) and (not largest or row.area > largest.area) then largest = row end
    end
    assert(largest and appearance.row(LUT, largest.row), 'a measured paint row')
    holder.pipeline.close()
    local function analyse_with(patched_gpu, cache)
        clear_patches()
        write_texture_patch('9ba626afa44a3aa3.patch_0', LUT, main, patched_gpu)
        deps.cache_path = cache
        holder = {}
        run(request)
        local a = analysis_of(holder.pipeline, HELMET)
        local row
        for _, r in ipairs(a.rows) do if r.key == largest.key then row = r end end
        local item = Matcher.item(a.rows, false, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
        local item_row
        for _, r in ipairs(item.rows) do if r.key == largest.key then item_row = r end end
        return a, row, item_row
    end
    local cache = root .. '/build/test-job-review.cache'
    os.remove(cache)
    -- the GPU part padded past Patches.SMALL: its bytes no longer enter the patch signature (as an ID mask's or a
    -- unit's), so only the analyses' content hashes can see an equal-size change
    gpu = gpu .. string.rep('\0', Patches.SMALL + 4096 - #gpu)
    -- a color change (the base color red): the response is kept, the archived row recorded
    local red = poke(gpu, largest.row, 0, 0, '\0\60\0\0\0\0')
    local a, row, item_row = analyse_with(red, cache)
    assert(row.finish_changed == false and row.vanilla and math.abs(row.vanilla.L - largest.L) < 1e-9,
           'a color-only change, its archived color recorded')
    assert(not a.geometry_patched and item_row.cal ~= nil, 'still measured, through its response')
    assert(a.patch_deps and #a.patch_deps == 1 and a.patch_deps[1].name == LUT
           and a.patch_deps[1].hash:match('^%d+:%x+$'), 'the patched LUT and its content hash recorded')
    holder.pipeline.save()
    local header = holder.pipeline.header
    holder.pipeline.close()
    -- the same patch next session: the cached analysis is used
    a = analyse_with(red, cache)
    assert(a.cached and a.patch_deps and #a.patch_deps == 1, 'cached analysis reused, its check passed')
    holder.pipeline.close()
    -- the same size, other content (green): the cached analysis no longer holds and is made again
    local green = poke(gpu, largest.row, 0, 0, '\0\0\0\60\0\0')
    a, row = analyse_with(green, cache)
    assert(holder.pipeline.header == header, 'the patch signature cannot see this change')
    assert(not a.cached and row.ag > row.ar, 'an equal-size change is caught: analysed again from the new patch')
    holder.pipeline.close()
    -- a finish change (metallic, column 6 w): the measured response no longer holds
    local w_at = (largest.row * 23 + 6) * 8 + 6
    local metallic = gpu:byte(w_at + 1) + gpu:byte(w_at + 2) * 256
    local flipped = poke(gpu, largest.row, 6, 3, metallic == 0x3C00 and '\0\0' or '\0\60')
    a, row, item_row = analyse_with(flipped, root .. '/build/test-job-review2.cache')
    assert(row.finish_changed == true and item_row.cal == nil, 'a finish change: its model color, no response')
    assert(not a.geometry_patched, 'the geometry is the archived one')
    holder.pipeline.close()
    os.remove(cache)
    os.remove(root .. '/build/test-job-review2.cache')
    deps.cache_path = CACHE
    clear_patches()
end)

check('a kit record recomposed at runtime (a transmog\'s carrier: same id, other pieces) is read again by the next job '
      .. 'and analysed anew; the result carries what the records listed', function()
    holder = {}
    local request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719,
                     body = 0}
    local first = run(request)
    local p = holder.pipeline
    local before = p.kits.signature(0xa5574ac2)
    assert(first.signatures and first.signatures[0xa5574ac2] == before, 'the result names the records it was made of')
    -- the carrier now lists the RS-100 Sanctioner's pieces under the Bulwark's id (the transmog's composition)
    local composed = {}
    for _, k in ipairs(chosen) do
        if k.id == HELMET then
            local hooded
            for _, h in ipairs(chosen) do if h.id == HOODED then hooded = h end end
            local copy = {}
            for f, v in pairs(k) do copy[f] = v end
            copy.pieces, copy.archive = hooded.pieces, hooded.archive
            composed[#composed + 1] = copy
        else
            composed[#composed + 1] = k
        end
    end
    catalogue(space, composed)
    assert(p.kits.signature(0xa5574ac2) ~= before, 'the record reads otherwise now')
    local second = run(request)
    local kit = p.kits.find(0xa5574ac2)
    assert(kit.archive == (function() for _, h in ipairs(chosen) do if h.id == HOODED then return h.archive end end end)(),
           'the job read the recomposed record')
    assert(second.signatures[0xa5574ac2] ~= before and second.key ~= first.key, 'a new plan for the new pieces')
    catalogue(space, chosen)
    p.close()
end)

print('PASS test_job (' .. passed .. ' checks)')
