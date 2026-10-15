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
require('sheets').attach(Recolor)
local Cache, Transfer, Patches, Schemes = require('cache'), require('transfer'), require('patches'), require('schemes')
local Capes = require('capes')
local appearance = require('appearance').new(require('appearance_data'))
local Fake = dofile(root .. '/tests/fake_game.lua')
Matcher.use(Colour)
require('zones').attach(Matcher, Colour)
require('variety').attach(Matcher, Colour)
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
-- a cape with a yellow emblem (0.5% of the cape): Helmet and Armor Match Cape takes emblems as source colors
local EMBLEM_CAPE = 'c1105fbc'
-- an end user's lime-green report (2026-10-08): the CE-27 Ground Breaker with a mod patching its geometry, and helmets
-- of the screenshots (CE-64 Grenadier, RS-20 Constrictor)
local GROUND_BREAKER, GRENADIER, CONSTRICTOR = '7edf6505', '4e0785ae', 'e4e2b61b'
-- the DP-11 Champion of the People set: a recolor mod replacing all its LUTs with R32G32B32A32_FLOAT textures made
-- every recolor touching it fail on v1.3 / Megapack v40 (user ticket 2026-10-09: "LUT mods completely break the mod")
local DP11_HELMET, DP11_ARMOR = 'ef6d2ad3', 'e3aaa79d'
-- armors whose clothing sits on pieces with skin tones (user ticket 2026-10-09: "the shirt on the stomach ... stays the
-- default yellow and green"): the PH-9 Predator's and PH-56 Jaguar's camo shirts, whose LUTs only such pieces use
local PREDATOR, JAGUAR = '72b472a7', '23d0e15c'
-- the CM-21 Trench Paramedic set (SEAF review 2026-10-09: white boots, a red visor); the SA-12 Twigsnapper (SEAF
-- review round 9: black trousers, white splashes on its camo plates)
local PARAMEDIC_HELMET, PARAMEDIC_ARMOR, TWIGSNAPPER = 'bd1e5e84', 'd52bb413', 'de631a28'
-- the RS-40 Beast of Prey under the yellow-emblem cape (independent review 2026-10-09: its brown gloves and boots white)
local RS40 = 'dbc21a99'
-- the IX-VOIDWALKER's navy band on the RE-1861 Parade Commander (user 2026-10-09: "turns pitch black")
local VOIDWALKER, PARADE = '6478678e', 'c71dbba4'
-- the B-24 Enforcer: its dark reds (16%) too dark to be its visible accent; the band takes their hue all the same
local ENFORCER = '8b9ed77d'
-- a white glossy B-01 Tactical helmet on the CM-14 Physician (user 2026-10-10: helmets' grey slightly darker)
local WHITE_B01, PHYSICIAN = '2180eb8d', '38aa207d'
-- the B-22 Model Citizen under the black camo cape 4100af4b (user 2026-10-10: its shin guards pitch black)
local MODEL_CITIZEN, BLACK_CAPE = 'cb7e9736', '4100af4b'
-- the SC-30 Trailblazer Scout under the AF-50 Noxious Ranger's glossy olive mask (user 2026-10-10: its coat "much
-- lighter tint than the helmet's green")
local TRAILBLAZER, NOXIOUS = '1d60fc90', 'de575ea9'
-- the SR-64 Cinderblock under the Thundering Hooves of Loyalty (user 2026-10-10: "pure red ... losing the accenting")
local CINDERBLOCK = '5096bce9'
-- the FS-37 Ravager (SET_ARMOR) under the black cape 0beb97bc with its 21% red (gallery 2026-10-11: the whole armor one
-- dark grey)
local RED_CAPE = '0beb97bc'
-- the B-24 Enforcer (ENFORCER) under the black and yellow cape d79370cb (gallery 2026-10-11: its coat rust brown)
local YELLOW_CAPE = 'd79370cb'
-- the CPR-80 Bulwark (HELMET) under Red Planet's Memory (user 2026-10-11: "48 is very broken. The helmet went pure
-- black.")
local RED_PLANET = '9ce65da7'
-- the O-3 Free Spirit under Vision of Freedom (black outside, grey lining) and the I-92 Fire Fighter helmet under the
-- dark grey Triangulation Veil (independent review 2026-10-11: cases 57, 110; the user chose "outside first" and
-- "repaint for capes")
local FREE_SPIRIT, VISION = 'f7e6f127', '457526d1'
local FIRE_FIGHTER, TRIANGULATION = 'fd428984', '06d37083'
-- the CE-101 Guerilla Gorilla helmet under da9ebb65 (navy 57%, mostly outside; red 35%, all outside: round 30)
local GORILLA, NAVY_CAPE = '89b1b9e3', 'da9ebb65'
-- the TR-7 Ambassador of the Brand armor's cyan plates under the black cape bd961a7c (5% navy hem; review case 120)
local AMBASSADOR, HEM_CAPE = '8a957897', 'bd961a7c'
-- the UF-16 Inspector's red cloth sleeve under the navy cape 92762946 (independent review 2026-10-11, case 33: purple)
local INSPECTOR, SLEEVE_CAPE = 'b661572a', '92762946'
-- the CW-4 Arctic Ranger armor, whose grey goal under the CPR-80 Bulwark helmet lies under its response's floor
local ARCTIC_RANGER = 'b92e1781'
-- the EX-00 Prototype X helmet's grey dome under Standard of Safe Distance's taupe lining (independent review
-- 2026-10-11, case 70)
local PROTOTYPE_X, SAFE_DISTANCE = 'd1a64ac3', '14712621'
-- the fresh gallery's failures (independent review 2026-10-11; the user chose to fix 36, 37, 80, 103): the BP-32
-- Jackboot all black under 1264718e's yellow, the FS-23 Battle Master's yellow stripes under the grey e7619545, the
-- IE-3 Martyr's olive undersuit under Federation's Embrace, the FS-05 Marksman's dome teal under Honored Heirloom
local JACKBOOT, YELLOW_HALF = '09b08ec4', '1264718e'
local BATTLE_ARMOR, GREY_CAPE = '26d572a4', 'e7619545'
local MARTYR, FEDERATION = 'b028b970', '1b3bd8a1'
local MARKSMAN, HEIRLOOM = 'e417ae7b', '52f858a8'
local chosen = {}
for _, kit in ipairs(KITS) do
    if kit.id == HELMET or kit.id == ARMOR or kit.id == HOODED or kit.id == TRENCH or kit.id == SET_HELMET
        or kit.id == SET_ARMOR or kit.id == WINTER_WARRIOR or kit.id == HAZ_MASTER or kit.id == B01_HELMET
        or kit.id == B01_ARMOR or kit.id == GROUND_BREAKER or kit.id == GRENADIER or kit.id == CONSTRICTOR
        or kit.id == DP11_HELMET or kit.id == DP11_ARMOR or kit.id == PREDATOR or kit.id == JAGUAR
        or kit.id == PARAMEDIC_HELMET or kit.id == PARAMEDIC_ARMOR or kit.id == TWIGSNAPPER or kit.id == RS40
        or kit.id == VOIDWALKER or kit.id == PARADE or kit.id == ENFORCER or kit.id == WHITE_B01
        or kit.id == PHYSICIAN or kit.id == MODEL_CITIZEN or kit.id == TRAILBLAZER or kit.id == NOXIOUS
        or kit.id == CINDERBLOCK or kit.id == FREE_SPIRIT or kit.id == FIRE_FIGHTER or kit.id == GORILLA
        or kit.id == AMBASSADOR or kit.id == INSPECTOR or kit.id == ARCTIC_RANGER or kit.id == PROTOTYPE_X
        or kit.id == JACKBOOT or kit.id == BATTLE_ARMOR or kit.id == MARTYR or kit.id == MARKSMAN then
        chosen[#chosen + 1] = kit
    end
end
-- the Thundering Hooves of Loyalty (red 55%, gold 40%): on the B-01 Tactical "it just colors the entire armor red. No
-- accenting at all" (user 2026-10-09)
local HOOVES = '5a32915a'
local cover, united, drape, emblem_cape, hooves, black_cape, red_cape, yellow_cape, red_planet, vision, triangulation
local navy_cape, hem_cape, sleeve_cape, safe_distance
local fresh_capes = {}
for _, kit in ipairs(CAPES) do
    if kit.id == YELLOW_HALF or kit.id == GREY_CAPE or kit.id == FEDERATION or kit.id == HEIRLOOM then
        fresh_capes[#fresh_capes + 1] = kit
    end
    if kit.id == SLEEVE_CAPE then sleeve_cape = kit end
    if kit.id == SAFE_DISTANCE then safe_distance = kit end
    if kit.id == YELLOW_CAPE then yellow_cape = kit end
    if kit.id == RED_PLANET then red_planet = kit end
    if kit.id == VISION then vision = kit end
    if kit.id == TRIANGULATION then triangulation = kit end
    if kit.id == NAVY_CAPE then navy_cape = kit end
    if kit.id == HEM_CAPE then hem_cape = kit end
    if kit.id == COVER_OF_DARKNESS then cover = kit end
    if kit.id == UNITED then united = kit end
    if kit.id == DRAPE then drape = kit end
    if kit.id == EMBLEM_CAPE then emblem_cape = kit end
    if kit.id == HOOVES then hooves = kit end
    if kit.id == BLACK_CAPE then black_cape = kit end
    if kit.id == RED_CAPE then red_cape = kit end
end
chosen[#chosen + 1] = cover
chosen[#chosen + 1] = united
chosen[#chosen + 1] = drape
chosen[#chosen + 1] = emblem_cape
chosen[#chosen + 1] = hooves
chosen[#chosen + 1] = black_cape
chosen[#chosen + 1] = red_cape
chosen[#chosen + 1] = yellow_cape
chosen[#chosen + 1] = red_planet
chosen[#chosen + 1] = vision
chosen[#chosen + 1] = triangulation
chosen[#chosen + 1] = navy_cape
chosen[#chosen + 1] = hem_cape
chosen[#chosen + 1] = sleeve_cape
chosen[#chosen + 1] = safe_distance
for _, kit in ipairs(fresh_capes) do chosen[#chosen + 1] = kit end
assert(#fresh_capes == 4 and #chosen == 60 and cover and united and drape and emblem_cape and hooves and black_cape and red_cape
       and yellow_cape and red_planet and vision and triangulation and navy_cape and hem_cape and sleeve_cape
       and safe_distance, 'fixture kits')
-- The v1.5 tickets' kits (user reports 2026-10-14), added by id: the B-22 Model Citizen helmet under the Eye of Liberty
-- (Match Materials: "only the color gets translated"); the default black cape Foesmasher on the B-01 Tactical and the
-- DS-42 Federation's Blade ("black in the default capes is grey when applied to armour").
local B22_HELMET, EYE_OF_LIBERTY = 'ec49526f', '1b03e942'
local FOESMASHER, DS42_ARMOR = '4657cfb3', '4a545f06'
-- the CE-74 Breaker helmet (tan): the skin-tone clothing check's helmet since v1.5 (with the CPR-80 Bulwark the PH-9
-- Predator's camo shirt now takes an olive drab of the Bulwark's yellow, its own olive within a hair)
local BREAKER = 'ee2e8ce0'
-- Diagram of the Noblest Payload: a cape whose emblem row is hard bare metal (no part takes it as metal), and the FS-55
-- Devastator that would have (the mutation audit, 2026-10-14)
local DIAGRAM, DEVASTATOR = 'a7945016', 'd3461392'
local V15_KITS = {B22_HELMET, EYE_OF_LIBERTY, FOESMASHER, DS42_ARMOR, BREAKER, DIAGRAM, DEVASTATOR}
do
    local wanted, have = {}, {}
    for _, id in ipairs(V15_KITS) do wanted[id] = true end
    for _, kit in ipairs(chosen) do have[kit.id] = true end
    for _, list in ipairs({KITS, CAPES}) do
        for _, kit in ipairs(list) do
            if wanted[kit.id] then
                if not have[kit.id] then chosen[#chosen + 1], have[kit.id] = kit, true end
                wanted[kit.id] = nil
            end
        end
    end
    assert(next(wanted) == nil, 'v1.5 fixture kits: ' .. tostring(next(wanted)))
end
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
              Albedo = require('albedo'),
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
    local resumes, ok, result, stages = 0, nil, nil, {}
    repeat
        ok, result = coroutine.resume(co)
        assert(ok, tostring(result))
        assert(coroutine.status(co) == 'dead' or type(holder.stage) == 'string', 'a pause without a stage')
        if coroutine.status(co) ~= 'dead' then stages[holder.stage] = true end
        resumes = resumes + 1
    until coroutine.status(co) == 'dead'
    return result, resumes, stages
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
    local result, _, stages = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2,
                                   armor = 0x0ade6719, body = 0})
    local p = holder.pipeline
    assert(p.cache_status == '2 kit analyses loaded', tostring(p.cache_status))
    -- the first job's pauses name the step they are in (the release smokes' 4.6-4.9 ms "kit catalogue" slice was the
    -- cache's samples block)
    for _, name in ipairs({'reading the analysis cache', 'decoding the analysis cache'}) do
        assert(stages[name], 'a pause in the stage ' .. name)
    end
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

check('work ahead of the Helldiver (src/addon.lua plan_ahead): a request without kits builds the pipeline alone, the '
      .. 'game data reader never opened; after the kits\' job, the Helldiver\'s job of the same request pauses nowhere '
      .. 'and reads nothing (user report 2026-10-08: the first recolor came 7 frames of job after the Helldiver)', function()
    holder = {}
    local request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719,
                     body = 0}
    run(request)
    holder.pipeline.close()
    assert(holder.pipeline.save(), 'saved')
    holder = {} -- a new session, on a loading screen
    local result, _, stages = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, body = 0})
    local p = holder.pipeline
    assert(result.action == 'prepared' and p and p.cache_status == '2 kit analyses loaded', tostring(p and p.cache_status))
    assert(stages['decoding the analysis cache'] and p.files == nil and p.reads == 0, 'the cache decoded, no game file')
    local ahead = run(request) -- the kits known before the Helldiver
    p.close()
    local found, resumes = run(request) -- the Helldiver's own job
    assert(resumes == 1 and p.files == nil and p.reads == 0, 'no pause, nothing read: ' .. resumes .. ' resumes')
    for name, spec in pairs(ahead.luts) do
        assert(found.luts[name] == spec, 'the plan made ahead: ' .. name)
    end
    assert(found.key == ahead.key and found.action == 'apply', 'the same result')
    os.remove(CACHE)
end)

check('decoded small chunks are kept for the reader\'s life (2026-10-08: about half of a new item\'s reads decoded the '
      .. 'same small chunks again): the same bytes with and without, and reading the resources again reads less', function()
    local armor
    for _, kit in ipairs(chosen) do if kit.id == ARMOR then armor = kit end end
    -- each piece's unit head and LUT texture head, twice (as an analysis comes back to a material or texture)
    local function read_all(slim, files, out)
        for round = 1, 2 do
            if round == 2 then out.first_round_reads = files.reads end
            for _, piece in ipairs(armor.pieces) do
                for _, item in ipairs({{piece.path, Kits.TYPE_UNIT}, {piece.lut, Kits.TYPE_TEXTURE}}) do
                    local record = slim.locate(armor.archive, item[1], item[2]) -- the kit's own archive's only
                    if record then
                        local size = math.min(slim.part_size(record, 'main'), 256)
                        local buffer = ffi.new('uint8_t[?]', math.max(1, size))
                        slim.part(armor.archive, record, 'main', 0, size, buffer, 0)
                        out[#out + 1] = ffi.string(buffer, size)
                    end
                end
            end
        end
        return out
    end
    local function run_with(small)
        local was = Slim.SMALL_CHUNK
        Slim.SMALL_CHUNK = small
        local files = Files.new(game_root .. '/data/')
        local slim = Slim.open(files, '')
        local ok, bytes = pcall(read_all, slim, files, {})
        Slim.SMALL_CHUNK = was
        slim.close()
        assert(ok, tostring(bytes))
        return bytes, files.reads - bytes.first_round_reads
    end
    local without, again_without = run_with(0)
    local with, again_with = run_with(16384)
    assert(#with == #without and #with > 0, 'the same resources read')
    for i = 1, #with do assert(with[i] == without[i], 'the same bytes, read ' .. i) end
    -- offline 2026-10-08: 48 resources, the second pass 28 reads without, none with
    assert(again_with == 0 and again_without > 0, string.format('read again: %d reads with, %d without', again_with,
                                                                again_without))
    -- the kept bytes never pass Slim.SMALL_BYTES: everything let go at once, read again, the same bytes
    local budget = Slim.SMALL_BYTES
    Slim.SMALL_BYTES = 6000
    local files = Files.new(game_root .. '/data/')
    local slim = Slim.open(files, '')
    local ok, bytes = pcall(read_all, slim, files, {})
    local kept = slim.scratch.small_bytes
    Slim.SMALL_BYTES = budget
    slim.close()
    assert(ok, tostring(bytes))
    assert(kept > 0 and kept <= 6000, 'kept bytes within the budget: ' .. kept)
    for i = 1, #with do assert(bytes[i] == with[i], 'the same bytes under a small budget, read ' .. i) end
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
    local made -- the cape's plan (keyed by the cape and its source, not by the result)
    for _, plan in pairs(p.plans) do if plan.luts[piece.cape_lut] == spec then made = plan end end
    assert(made, 'the cape plan kept')
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
    local made -- the cape's plan (keyed by the cape and its source, not by the result)
    for _, plan in pairs(p.plans) do if plan.luts[piece.lut] == result.luts[piece.lut] then made = plan end end
    assert(made, 'the cape plan kept')
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

check('Helmet and Armor Match Cape (user request 2026-10-09): both items take the Cover of Darkness\'s colors (slots '
      .. '0-9) and the cape keeps its own, Recolor Cape on too; a complete set takes them as well; without a cape the '
      .. 'items keep theirs; a paint scheme still overrides the mode', function()
    holder = {}
    local cape_id = tonumber(COVER_OF_DARKNESS, 16)
    local request = {mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0,
                     cape = cape_id}
    local result = run(request)
    local CAPE_LUT = cover.pieces[1].lut
    assert(result.action == 'apply' and result.first == 0 and result.last == 9 and #result.targets == 2
           and not result.luts[CAPE_LUT] and result.luts['962a946e964ebc40'], 'helmet and armor, the cape as it is')
    assert(result.key:find('^capesrc:') and result.signatures[cape_id], 'keyed and signed by the cape: ' .. result.key)
    local p = holder.pipeline
    local cape, armor, helmet = analysis_of(p, COVER_OF_DARKNESS), analysis_of(p, ARMOR), analysis_of(p, HELMET)
    -- the cape as a source: its dark grey outside (54%), red lining (35%), grey sash (11%) and beige trim
    local s = Matcher.item(Capes.source_rows(cape, Colour), false, Capes.emblem_patterns(cape, Colour),
                           Recolor.source_look_of(cape, appearance))
    s.part_guard, s.cape_source = Capes.dark_parts_guard, true -- as the job's (src/recolor.lua source_item)
    local GREY, RED, SASH = cover.pieces[1].lut .. ':0', cover.pieces[1].lut .. ':4', cover.pieces[1].lut .. ':3'
    assert(s.groups[1].rep.key == GREY and s.groups[2].rep.key == RED and s.groups[3].rep.key == SASH, 'the cape\'s colors')
    local function plan_of(item)
        local t = Matcher.item(item.rows, item.kit.kit_type == 'Armor', Recolor.patterns_of(item),
                               Recolor.look_of(item, appearance))
        return t, Matcher.plan(t, s)
    end
    local function takes(t, plan, i) return plan[t.groups[i].rows[1].key] end
    -- the DS-191 Scorpion: its tan shell and dark parts the cape's dark grey, its vest the sash's grey, its scarf the red
    local t, plan = plan_of(armor)
    assert(takes(t, plan, 1).source == GREY and takes(t, plan, 1).L < 30, 'the shell dark grey')
    assert(takes(t, plan, 2).source == GREY and takes(t, plan, 3).source == GREY, 'the dark parts dark grey')
    assert(takes(t, plan, 4).source == SASH and takes(t, plan, 6).source == RED, 'the vest grey, the scarf red')
    -- the CPR-80 Bulwark: its steel the dark grey, its yellow stripes the red
    t, plan = plan_of(helmet)
    assert(takes(t, plan, 1).source == GREY and takes(t, plan, 2).kind == 'accent' and takes(t, plan, 2).source == RED,
           'the steel dark grey, the stripes red')
    local capes = {capes = true}
    for k, v in pairs(request) do capes[k] = v end
    local both = run(capes)
    assert(both.key == result.key and not both.luts[CAPE_LUT], 'Recolor Cape on: the cape is still the source only')
    local set = {mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(SET_HELMET, 16),
                 armor = tonumber(SET_ARMOR, 16), body = 0, cape = cape_id}
    local painted_set = run(set)
    assert(painted_set.action == 'apply' and painted_set.first == 0 and painted_set.last == 9, 'a complete set too')
    local bare = {}
    for k, v in pairs(request) do bare[k] = v end
    bare.cape = 0
    local kept = run(bare)
    assert(kept.action == 'restore' and kept.reason == 'no cape', 'no cape: the items keep their colors')
    local scheme = {scheme = 3}
    for k, v in pairs(request) do scheme[k] = v end
    local schemed = run(scheme)
    assert(schemed.key:find('^scheme:') and not schemed.signatures[cape_id], 'a paint scheme overrides the mode')
    p.close()
end)

check('Helmet and Armor Match Cape: a cape\'s tint is one color with its base, as the two show blended (United in '
      .. 'Equality\'s purple tint, 24% of it, painted an armor neon violet when taken apart; renders 2026-10-09)', function()
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(WINTER_WARRIOR, 16),
                armor = tonumber(HAZ_MASTER, 16), body = 0, cape = tonumber(UNITED, 16)}).action == 'apply', 'applied')
    local cape = analysis_of(holder.pipeline, UNITED)
    local rows, tint_rows, tint = Capes.source_rows(cape, Colour), 0, nil
    for _, row in ipairs(cape.rows) do
        if cape.tint_of[row.lut] then tint_rows, tint = tint_rows + 1, row end
    end
    assert(tint_rows > 0 and #rows == #cape.rows - tint_rows, 'each tint merged into its material row')
    local merged
    for _, row in ipairs(rows) do
        assert(not cape.tint_of[row.lut], 'no tint row of its own')
        if row.row == tint.row then merged = row end
    end
    local base
    for _, row in ipairs(cape.rows) do if row.lut == merged.lut and row.row == merged.row then base = row end end
    assert(math.abs(merged.area - (base.area + tint.area)) < 1e-12, 'the two areas')
    local function chroma(r) return math.sqrt(r.a * r.a + r.b * r.b) end
    assert(chroma(merged) < chroma(tint) and chroma(merged) > chroma(base), string.format(
           'between its base and its tint: chroma %.1f (base %.1f, tint %.1f)', chroma(merged), chroma(base), chroma(tint)))
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: the Drape of Glory\'s emblem (a dark grey sheet mark) is a source color, its share '
      .. 'its cells at the outside\'s weight over the cape\'s total; the total is kept in the disk cache', function()
    holder = {}
    local request = {mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                     armor = tonumber(B01_ARMOR, 16), body = 0, cape = tonumber(DRAPE, 16)}
    assert(run(request).action == 'apply', 'the Drape of Glory as the source')
    local p = holder.pipeline
    local cape = analysis_of(p, DRAPE)
    local e, patterns = cape.emblems[1], Capes.emblem_patterns(cape, Colour)
    local share = e.cells * Capes.W_OUT * Capes.TINT_STEPS / cape.weight
    assert(#patterns == 1 and patterns[1].pattern == 'emblem:0:' .. e.layer and patterns[1].area == share
           and share > 0 and share < 0.2, 'its emblem, share ' .. share)
    local L = Colour.srgb_to_lab(patterns[1].r, patterns[1].g, patterns[1].b)
    assert(math.abs(L - e.L) < 0.5, 'its own color: L ' .. L .. ', emblem ' .. e.L)
    local s = Matcher.item(Capes.source_rows(cape, Colour), false, patterns, Recolor.source_look_of(cape, appearance))
    assert(s.patterns[1] and math.abs(s.patterns[1].share - share) < 1e-12, 'a color of the cape item')
    assert(p.save(), 'saved')
    p.close()
    holder = {} -- a new session reads the cape's analysis from the cache
    local with = run(request)
    local cached = analysis_of(holder.pipeline, DRAPE)
    assert(cached.cached and cached.weight == cape.weight, 'the total from the cache')
    holder.pipeline.close()
    -- the job's source item has its emblems: a yellow emblem of 0.5% is the accent the Bulwark's stripes and the
    -- Scorpion's trims take (without it, other colors)
    request.helmet, request.armor, request.cape = 0xa5574ac2, 0x0ade6719, tonumber(EMBLEM_CAPE, 16)
    holder = {}
    with = run(request)
    holder.pipeline.close()
    local saved = Capes.emblem_patterns
    Capes.emblem_patterns = function() return {} end
    holder = {}
    local without = run(request)
    Capes.emblem_patterns = saved
    holder.pipeline.close()
    local differ = 0
    for name, spec in pairs(with.luts) do
        local other = without.luts[name]
        for i = 0, spec.width * spec.height * 4 - 1 do
            if not other or other.data[i] ~= spec.data[i] then differ = differ + 1 end
        end
    end
    assert(differ > 0, 'the emblem changes the colors')
    -- the RS-40 Beast of Prey under it: its dark brown gloves and boots stay dark (the cape's darkest), not its cream
    -- (independent image review 2026-10-09: "the boots and gloves turn white"); the job's source item has the guard
    request.armor = tonumber(RS40, 16)
    holder = {}
    local rs40 = run(request)
    assert(rs40.action == 'apply', 'the RS-40 under the yellow-emblem cape')
    local p2 = holder.pipeline
    local cape2, armor2 = analysis_of(p2, EMBLEM_CAPE), analysis_of(p2, RS40)
    local function source(guarded)
        local s = Matcher.item(Capes.source_rows(cape2, Colour), false, Capes.emblem_patterns(cape2, Colour),
                               Recolor.look_of(cape2, appearance))
        if guarded then s.part_guard = Capes.dark_parts_guard end
        return s
    end
    local t = Matcher.item(armor2.rows, true, Recolor.patterns_of(armor2), Recolor.look_of(armor2, appearance))
    local function light_on_dark(s)
        local plan, n = Matcher.plan(t, s), 0
        local light = {}
        for _, g in ipairs(s.groups) do if g.L >= Capes.LIGHT_COLOR_L then light[g.rep.key] = true end end
        for _, g in ipairs(t.groups) do
            local m = plan[g.rows[1].key]
            if m and light[m.source] and g.mL < Capes.DARK_PART_L and math.sqrt(g.ma ^ 2 + g.mb ^ 2) < 20 then
                n = n + 1
            end
        end
        return n
    end
    assert(light_on_dark(source(false)) > 0, 'unguarded, a dark part takes the cape\'s cream')
    assert(light_on_dark(source(true)) == 0, 'guarded, dark parts stay dark')
    -- in the job's LUTs too: the rows the unguarded plan made cream are dark
    local unguarded, checked = Matcher.plan(t, source(false)), 0
    for _, g in ipairs(t.groups) do
        local m = unguarded[g.rows[1].key]
        if m and m.L >= Capes.LIGHT_COLOR_L and g.mL < Capes.DARK_PART_L then
            for _, row in ipairs(g.rows) do
                local spec = assert(rs40.luts[row.lut], 'LUT ' .. row.lut)
                local o = row.row * spec.width * 4
                local L = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
                assert(L < 50, string.format('%s stays dark in the job: L %.1f', row.key, L))
                checked = checked + 1
            end
        end
    end
    assert(checked > 0, 'rows checked')
    p2.close()
end)

check('Helmet and Armor Match Cape on a near one-color item (the B-01 Tactical, one black group of 94.5%) splits it by '
      .. 'material: plates the cape\'s main color, clothing its second, gear its darkest; an item of several colors '
      .. 'pairs as before (user 2026-10-09: the Thundering Hooves of Loyalty "just colors the entire armor red")',
      function()
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                        armor = tonumber(B01_ARMOR, 16), body = 0, cape = tonumber(HOOVES, 16)})
    assert(result.action == 'apply', 'the B-01 set under the Thundering Hooves of Loyalty')
    local p = holder.pipeline
    local cape = analysis_of(p, HOOVES)
    local s = Matcher.item(Capes.source_rows(cape, Colour), false, Capes.emblem_patterns(cape, Colour),
                           Recolor.source_look_of(cape, appearance))
    s.part_guard, s.cape_source = Capes.dark_parts_guard, true
    local function plan_of(id)
        local a = analysis_of(p, id)
        local t = Matcher.item(a.rows, a.kit.kit_type == 'Armor', Recolor.patterns_of(a), Recolor.look_of(a, appearance))
        return t, Schemes.plan(Matcher, nil, t, s, false, false)
    end
    local RED, GOLD = s.groups[1].rep.key, s.groups[2].rep.key
    assert(s.groups[1].a > 30 and s.groups[2].b > 30, 'the cape: red, then gold')
    local t, plan = plan_of(B01_ARMOR)
    local by = {}
    for _, row in ipairs(t.rows) do
        local m = plan[row.key]
        if m then by[m.source] = (by[m.source] or 0) + row.area / t.paint_area end
    end
    local colors = 0
    for _, share in pairs(by) do if share >= 0.15 then colors = colors + 1 end end
    assert(colors >= 3 and (by[RED] or 0) > 0.15 and (by[GOLD] or 0) > 0.25, string.format(
           'three colors on the armor: red %.2f, gold %.2f', by[RED] or 0, by[GOLD] or 0))
    -- the cape's main color is its outside's, the gold (its red, 55%, is the lining: row 4; the user chose "outside
    -- first", 2026-10-11): the plates gold, the clothing and trims its second, the red (until then the reverse)
    assert(plan['c7bb2c83d13561fd:0'].source == GOLD and plan['a0d85b3a43ec0caa:0'].source == RED
           and plan['a0d85b3a43ec0caa:2'].source ~= GOLD, 'plates gold, jacket red, gloves not gold')
    assert(plan['a0d85b3a43ec0caa:1'].source == RED, 'its yellow trim the cape\'s red')
    -- in the job's LUTs too: the jacket's row is red, not gold
    local spec = assert(result.luts['a0d85b3a43ec0caa'], 'the jacket\'s LUT')
    local _, ja, jb = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(ja > jb, string.format('the jacket red, not gold: a %.1f b %.1f', ja, jb))
    p.close()
    -- an item of several colors (the RS-40, its main 51%) pairs by area and lightness as before
    holder = {}
    run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(RS40, 16), body = 0,
         cape = tonumber(HOOVES, 16)})
    p = holder.pipeline
    local rs40 = analysis_of(p, RS40)
    local tt = Matcher.item(rs40.rows, true, Recolor.patterns_of(rs40), Recolor.look_of(rs40, appearance))
    local split = Schemes.plan(Matcher, nil, tt, s, false, false)
    local paired = Matcher.plan(tt, s)
    for key, m in pairs(paired) do assert(split[key] and split[key].source == m.source, 'paired as before: ' .. key) end
    p.close()
    -- a two-color armor (the SR-64 Cinderblock: dark 72%, light grey plates 19%) keeps the cape's two colors: its dark
    -- main the red, its plates the gold (user 2026-10-10: "pure red with the red/yellow cape, losing the accenting
    -- entirely": the gold, a vivid color of 40%, was guarded off every muted part and the red anchored on the plates)
    holder = {}
    run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(CINDERBLOCK, 16), body = 0,
         cape = tonumber(HOOVES, 16)})
    p = holder.pipeline
    local cb = analysis_of(p, CINDERBLOCK)
    local ct = Matcher.item(cb.rows, true, Recolor.patterns_of(cb), Recolor.look_of(cb, appearance))
    local cplan = Schemes.plan(Matcher, nil, ct, s, false, false)
    assert(cplan['c2ea0c8bcefebad3:0'].source == RED, 'the Cinderblock\'s dark main the red')
    assert(cplan['62936f97158fe9d7:2'].source == GOLD, 'its light grey plates the gold: ' .. cplan['62936f97158fe9d7:2'].source)
    p.close()
end)

check('Helmet and Armor Match Cape: a cape of black and one vivid color (0beb97bc: black 79%, red 21%) keeps both on '
      .. 'the FS-37 Ravager, its olive plates red and the rest black; a helmet or armor source keeps the vivid guard '
      .. '(gallery 2026-10-11: the whole armor one dark grey, the red on a 0.4% speck)', function()
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(SET_ARMOR, 16),
                        body = 0, cape = tonumber(RED_CAPE, 16)})
    assert(result.action == 'apply', 'the Ravager under the cape')
    local p = holder.pipeline
    local cape, a = analysis_of(p, RED_CAPE), analysis_of(p, SET_ARMOR)
    local s = Matcher.item(Capes.source_rows(cape, Colour), false, Capes.emblem_patterns(cape, Colour),
                           Recolor.source_look_of(cape, appearance))
    s.part_guard, s.cape_source = Capes.dark_parts_guard, true
    local BLACK, RED = s.groups[1].rep.key, s.groups[2].rep.key
    assert(#s.groups == 2 and s.groups[2].a > 25, 'the cape: black, then red')
    local t = Matcher.item(a.rows, true, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
    local plan = Schemes.plan(Matcher, nil, t, s, false, false)
    local by = {}
    for _, row in ipairs(t.rows) do
        local m = plan[row.key]
        if m then by[m.source] = (by[m.source] or 0) + row.area / t.paint_area end
    end
    assert((by[RED] or 0) > 0.15 and (by[RED] or 0) < 0.35 and (by[BLACK] or 0) > 0.6, string.format(
           'black and red near the cape\'s 79/21: black %.2f, red %.2f', by[BLACK] or 0, by[RED] or 0))
    assert(plan['4de1865b60971124:2'].source == RED, 'its olive plates the red')
    assert(plan['312f5d64a1f35ad8:2'].source == BLACK and plan['312f5d64a1f35ad8:6'].source == BLACK,
           'its brown suit and black parts black')
    -- in the job's LUTs too: the plates' row red
    local spec = assert(result.luts['4de1865b60971124'], 'the plates\' LUT')
    local o = 2 * spec.width * 4
    local _, ra, rb = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
    assert(ra > 20 and ra > rb, string.format('the plates red: a %.1f b %.1f', ra, rb))
    -- the same colors from a helmet or armor: a vivid color of 10% or more (21% here) is no minority, its plates red
    -- too (the user's version comparisons 2026-10-15: the FS-05 Marksman's red never reached the Ravager)
    s.cape_source = nil
    assert(Schemes.plan(Matcher, nil, t, s, false, false)['4de1865b60971124:2'].source == RED, 'red without a cape too')
    p.close()
end)

check('a near-neutral goal fitted through a measured response cancels the row\'s own cast: the B-24 Enforcer\'s coat '
      .. '(response R 1.08, B 0.87) under the black cape d79370cb gets a cool paint, no more saturated than its goal '
      .. '(gallery 2026-10-11: the coat rust brown, L 40 a 6.7 b 10.4, its goal L 33.6 a 2.2 b 3.2)', function()
    -- the neutral goal as v1.4 planned it: without src/variety.lua's balance (v1.5 gives the coat a secondary, below)
    local balance = Matcher.balance
    Matcher.balance = nil
    holder = {}
    local request = {mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(ENFORCER, 16),
                     body = 0, cape = tonumber(YELLOW_CAPE, 16)}
    local result = run(request)
    Matcher.balance = balance
    assert(result.action == 'apply', 'the Enforcer under the cape')
    local spec = assert(result.luts['98ce638cf129b632'], 'the coat\'s LUT')
    local L, a, b = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(L > 20 and L < 35 and b < -1 and math.sqrt(a * a + b * b) < 4.5,
           string.format('the coat a cool dark paint against its warm response: L %.1f a %.1f b %.1f', L, a, b))
    holder.pipeline.close()
    -- v1.5: the cape has no secondary of its own (its grey is 2% of it, its yellow vivid), so src/variety.lua leaves the
    -- plan as made: the coat the same cool dark paint. A drab of the yellow read olive, a color the cape does not have
    -- (independent review 1 2026-10-14; the user: the published look was better than a shade "from nowhere")
    holder = {}
    result = run(request)
    spec = assert(result.luts['98ce638cf129b632'], 'the coat\'s LUT')
    local L1, a1, b1 = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(math.abs(L1 - L) < 0.01 and math.abs(a1 - a) < 0.01 and math.abs(b1 - b) < 0.01, string.format(
           'the coat as made: L %.1f a %.1f b %.1f (without the rule L %.1f a %.1f b %.1f)', L1, a1, b1, L, a, b))
    holder.pipeline.close()
end)

check('a bare-metal part the fit darkens keeps a paint of L 45 or more: the CPR-80 Bulwark\'s steel under Red Planet\'s '
      .. 'Memory is a dark steel, not a black mirror (user 2026-10-11: "48 is very broken. The helmet went pure black."; '
      .. 'its paint was L 31)', function()
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(HELMET, 16),
                        armor = tonumber(ARMOR, 16), body = 0, cape = tonumber(RED_PLANET, 16)})
    assert(result.action == 'apply', 'the Bulwark under Red Planet\'s Memory')
    local spec = assert(result.luts['962a946e964ebc40'], 'the steel\'s LUT')
    for _, r in ipairs({0, 1}) do
        local o = r * spec.width * 4
        local L = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
        assert(L >= 44.5 and L < 56 and spec.data[o + 27] > 0.5, -- column 6 w: metallic
               string.format('steel row %d a dark metal paint: L %.1f, metallic %.2f', r, L, spec.data[o + 27]))
    end
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape keeps a one-color item\'s chrome with Match Materials off: the B-22 Model Citizen '
      .. 'helmet (chrome 89%) under the Eye of Liberty is a dark chrome; with the option on it is the cape\'s gold metal '
      .. '(user report 2026-10-14, "only the color gets translated": v1.4 made it matte cloth either way; independent '
      .. 'review 1: it went flat grey, the user chose "hard parts gold metal")', function()
    for _, materials in ipairs({false, true}) do
        holder = {}
        local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, materials = materials,
                            helmet = tonumber(B22_HELMET, 16), armor = tonumber(ARMOR, 16), body = 0,
                            cape = tonumber(EYE_OF_LIBERTY, 16)})
        assert(result.action == 'apply', 'the B-22 helmet under the Eye of Liberty')
        local spec = assert(result.luts['7d27f46409a3e60c'], 'the chrome\'s LUT')
        for _, r in ipairs({0, 2, 3}) do
            local o = r * spec.width * 4
            local metallic, roughness = spec.data[o + 27], spec.data[o + 40] -- columns 6 w and 10 x
            local _, a, b = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
            local gold = b > 15 and math.abs(a) < 8 -- the Eye of Liberty's gold (b 30), not its black
            local ok = metallic > 0.9 and roughness < 0.2 and (materials == gold)
            assert(ok, string.format('materials %s: chrome row %d metallic %.2f roughness %.2f, paint a %.1f b %.1f',
                                     tostring(materials), r, metallic, roughness, a, b))
        end
        holder.pipeline.close()
    end
end)

-- A cape source item and a target's plan against it, as the job makes them (and the target item).
local function cape_plan(p, cape_id, target_id)
    local cape, a = analysis_of(p, cape_id), analysis_of(p, target_id)
    local s = Matcher.item(Capes.source_rows(cape, Colour), false, Capes.emblem_patterns(cape, Colour),
                           Recolor.source_look_of(cape, appearance))
    s.part_guard, s.cape_source = Capes.dark_parts_guard, true
    local t = Matcher.item(a.rows, a.kit.kit_type == 'Armor', Recolor.patterns_of(a), Recolor.look_of(a, appearance))
    return Schemes.plan(Matcher, nil, t, s, false, false), s, t
end

check('Helmet and Armor Match Cape under a default black cape: armors take the black as the cape shows it, not its '
      .. 'lighter model color (user report 2026-10-14: "black in the default capes is grey when applied to armour"): '
      .. 'Foesmasher\'s black is a look of L 21.5-24 (model 25.3), the B-01 Tactical\'s parts are no lighter on '
      .. 'average than their own black, the DS-42 Federation\'s Blade\'s white plates turn a matte dark', function()
    local function paint_L(values, width, r)
        local o = r * width * 4
        return (Colour.srgb_to_lab(values[o], values[o + 1], values[o + 2]))
    end
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                        armor = tonumber(B01_ARMOR, 16), body = 0, cape = tonumber(FOESMASHER, 16)})
    assert(result.action == 'apply', 'the B-01 under Foesmasher')
    local plan, s, t = cape_plan(holder.pipeline, FOESMASHER, B01_ARMOR)
    local id = Matcher.identity(s)
    assert(id.gL and id.gL > 21.5 and id.gL < 24 and id.mL > 25, string.format('the cape\'s black: look %s, model %.1f',
           tostring(id.gL), id.mL))
    assert(id.ga == id.ma and id.gb == id.mb, 'a neutral black keeps its model hue (its sheen gave its look a warm cast)')
    -- the B-01 is of one color: the cape split (src/schemes.lua) paints its rows, each through its own response
    local cal_of, split = {}, 0
    for _, row in ipairs(t.rows) do cal_of[row.key] = row.cal end
    for key, goal in pairs(plan) do
        if goal.all and cal_of[key] then
            assert(goal.cal, key .. ': a cape split row fits through its own response')
            split = split + 1
        end
    end
    assert(split > 0, 'cape split rows with a measured response')
    local a = analysis_of(holder.pipeline, B01_ARMOR)
    local before, after, n = 0, 0, 0
    for key, goal in pairs(plan) do
        local lut, r = key:match('^(%x+):(%d+)$')
        local spec, own = result.luts[lut], a.luts[lut]
        if goal.tone == 'accent' then -- v1.5: its trims an accent (src/variety.lua), a grey on the black
            assert(goal.L > 35, string.format('%s, the accent, aims at L %.1f', key, goal.L))
        elseif goal.tone then -- v1.5: the armor's secondary (src/variety.lua), a charcoal that still reads black
            assert(goal.L < 36, string.format('%s, the %s tone, aims at L %.1f', key, goal.tone, goal.L))
        elseif goal.source == id.rep.key and spec and own and own.values then
            assert(goal.L < id.gL + 2.5, string.format('%s aims at L %.1f, the cape %.1f', key, goal.L, id.gL))
            local was = paint_L(own.values, own.width, tonumber(r))
            if was < 35 then -- its own black parts
                before, after, n = before + was, after + paint_L(spec.data, spec.width, tonumber(r)), n + 1
            end
        end
    end
    assert(n >= 3 and after / n <= before / n + 1.5, string.format('%d black rows: paint L %.1f, their own %.1f', n,
           after / n, before / n))
    holder.pipeline.close()
    holder = {}
    result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                  armor = tonumber(DS42_ARMOR, 16), body = 0, cape = tonumber(FOESMASHER, 16)})
    assert(result.action == 'apply', 'the DS-42 under Foesmasher')
    local spec = assert(result.luts['6d92b667d2e73b77'], 'the DS-42\'s plates')
    local L = paint_L(spec.data, spec.width, 0)
    assert(L < 32 and spec.data[40] >= 0.67, string.format('its white plates a matte dark: L %.1f roughness %.2f', L,
           spec.data[40]))
    -- its glossy plates (row 1, roughness 0.40) take the game's dark paint's roughness from the cape's cloth
    local rough = spec.data[spec.width * 4 + 40]
    assert(math.abs(rough - Transfer.DARK_ROUGH) < 1e-6, string.format('glossy plates under the cloth: roughness %.3f',
           rough))
    holder.pipeline.close()
end)

check('Match Materials carries a helmet\'s bare metal onto an armor\'s hard paint (user report 2026-10-14: the B-22 '
      .. 'Model Citizen\'s chrome, "only the color gets translated"): each such row of the FS-37 Ravager is one coat of '
      .. 'the chrome\'s paint with its finish, fitted without a response or floor; off, none', function()
    for _, materials in ipairs({false, true}) do
        holder = {}
        local result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, materials = materials,
                            helmet = tonumber(B22_HELMET, 16), armor = tonumber(SET_ARMOR, 16), body = 0})
        assert(result.action == 'apply', 'the FS-37 Ravager from the B-22')
        local p = holder.pipeline
        local h, a = analysis_of(p, B22_HELMET), analysis_of(p, SET_ARMOR)
        local t = Matcher.item(a.rows, true, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
        local s = Matcher.item(h.rows, false, Recolor.patterns_of(h), Recolor.look_of(h, appearance))
        local transfer = Transfer.new(Colour, (p.model())) -- the job's pauses inside a fit: none here
        local coats = 0
        for key, goal in pairs(Matcher.plan(t, s, materials)) do
            if goal.coat then
                local lut, r = key:match('^(%x+):(%d+)$')
                r = tonumber(r)
                local own, spec = a.luts[lut], assert(result.luts[lut], key .. ': its LUT built')
                local data = ffi.new('float[?]', own.width * own.height * 4)
                ffi.copy(data, own.values, own.width * own.height * 16)
                Recolor.apply_finish(data, own.width, r, h, goal.finish)
                local c = Colour.row_values(data, own.width, r)
                transfer.fit(c, goal.L, goal.a, goal.b, nil, nil, 'metal')
                local base = r * own.width * 4
                for _, column in ipairs(Transfer.COLUMNS) do
                    for ch = 0, 2 do
                        local got, want = spec.data[base + column * 4 + ch], c[column * 4 + ch + 1]
                        assert(math.abs(got - want) < 1e-5, string.format('%s column %d: %.6f, one coat %.6f', key,
                               column, got, want))
                    end
                end
                assert(spec.data[base + 27] > 0.5, key .. ': metal')
                coats = coats + 1
            end
        end
        assert(materials == (coats > 0), string.format('Match Materials %s: %d rows turned metal', tostring(materials),
               coats))
        p.close()
    end
end)

check('a cape\'s metallic rows give their metal too (live 2026-10-14: the Eye of Liberty\'s gold went flat pale yellow '
      .. 'with its metallic zeroed): with Match Materials the FS-55 Devastator\'s hard paint turns into the metal of '
      .. 'Diagram of the Noblest Payload (a hard metal row) and of the Eye of Liberty (cloth-mode metal rows), each such '
      .. 'row built metal; its clothing never; with Match Materials off, none', function()
    for _, cape_id in ipairs({DIAGRAM, EYE_OF_LIBERTY}) do
        for _, materials in ipairs({false, true}) do
            holder = {}
            local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, materials = materials, helmet = 0xa5574ac2,
                                armor = tonumber(DEVASTATOR, 16), body = 0, cape = tonumber(cape_id, 16)})
            assert(result.action == 'apply', 'the outfit under the cape')
            local p = holder.pipeline
            local cape = analysis_of(p, cape_id)
            local s = Matcher.item(Capes.source_rows(cape, Colour), false, Capes.emblem_patterns(cape, Colour),
                                   Recolor.source_look_of(cape, appearance))
            s.part_guard, s.cape_source = Capes.dark_parts_guard, true
            local a = analysis_of(p, DEVASTATOR)
            local t = Matcher.item(a.rows, true, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
            local mode_of, coats = {}, 0
            for _, row in ipairs(t.rows) do mode_of[row.key] = row.mode end
            for key, goal in pairs(Schemes.plan(Matcher, nil, t, s, materials, false)) do
                if goal.coat then
                    assert(mode_of[key] == 0, key .. ': only hard paint turns into metal')
                    local lut, r = key:match('^(%x+):(%d+)$')
                    local spec = assert(result.luts[lut], key .. ': its LUT built')
                    assert(spec.data[(tonumber(r) * spec.width + 6) * 4 + 3] > 0.5, key .. ': built metal')
                    coats = coats + 1
                end
            end
            assert(materials == (coats > 0), string.format('%s, Match Materials %s: %d rows turned metal', cape_id,
                                                           tostring(materials), coats))
            p.close()
        end
    end
end)

-- Independent review 1 2026-10-14 (cases 4, 5): under the Eye of Liberty with Match Materials the gold went to clothing
-- as a pale yellow paint and no hard part showed gold; the user chose "hard parts gold metal" (src/schemes.lua
-- metal_second).
check('Helmet and Armor Match Cape with Match Materials, a cape whose second color is metal (the Eye of Liberty\'s '
      .. 'gold): the FS-55 Devastator\'s hard paint takes it as gold metal on most of its area, its clothing the '
      .. 'cape\'s black; with the option off its hard parts stay black', function()
    for _, materials in ipairs({true, false}) do
        holder = {}
        local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, materials = materials, helmet = 0xa5574ac2,
                            armor = tonumber(DEVASTATOR, 16), body = 0, cape = tonumber(EYE_OF_LIBERTY, 16)})
        assert(result.action == 'apply', 'the Devastator under the Eye of Liberty')
        local a = analysis_of(holder.pipeline, DEVASTATOR)
        local hard, gold, clothing, dark = 0.0, 0.0, 0.0, 0.0
        for _, row in ipairs(a.rows) do
            local spec = result.luts[row.lut]
            if spec and row.area > 0 then
                local o = row.row * spec.width * 4
                local L, _, b = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
                if row.mode < 0.5 and row.under < 0.5 * row.area then
                    hard = hard + row.area
                    if spec.data[o + 27] > 0.9 and b > 15 then gold = gold + row.area end
                elseif row.mode >= 0.5 and row.under >= 0.5 * row.area then
                    clothing = clothing + row.area
                    if L < 30 then dark = dark + row.area end
                end
            end
        end
        if materials then
            assert(gold >= 0.6 * hard, string.format('hard paint gold metal: %.2f of %.2f', gold, hard))
            assert(dark >= 0.8 * clothing, string.format('clothing the cape\'s black: %.2f of %.2f', dark, clothing))
        else
            assert(gold < 0.1 * hard, string.format('option off: hard paint not gold metal: %.2f of %.2f', gold, hard))
        end
        -- its helmet, the CPR-80 Bulwark (steel 79%, under the cape split's 80%), gilded too with the option on:
        -- review round 4 found it the cape's black beside the gilded armor (src/schemes.lua Schemes.metal_second)
        local steel = assert(result.luts['962a946e964ebc40'], 'the Bulwark\'s LUT')
        for _, r in ipairs({0, 1}) do
            local o = r * steel.width * 4
            local _, _, b = Colour.srgb_to_lab(steel.data[o], steel.data[o + 1], steel.data[o + 2])
            local is_gold = steel.data[o + 27] > 0.9 and b > 15
            assert(is_gold == materials, string.format('materials %s: the helmet\'s steel row %d metallic %.2f b %.1f',
                                                       tostring(materials), r, steel.data[o + 27], b))
        end
        holder.pipeline.close()
    end
end)

check('Helmet and Armor Match Cape takes the cape\'s outside as its main color, not its lining: the O-3 Free Spirit '
      .. 'under Vision of Freedom (black outside, a grey lining of 49%) is dark, not grey (independent review '
      .. '2026-10-11, case 57; the user chose "outside first")', function()
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(FREE_SPIRIT, 16),
                body = 0, cape = tonumber(VISION, 16)}).action == 'apply', 'the Free Spirit under the cape')
    local plan, s = cape_plan(holder.pipeline, VISION, FREE_SPIRIT)
    local identity = Matcher.identity(s)
    assert(identity.rep.key == 'e200d7b29ba656bd:0' and identity.L < 25, string.format(
           'the identity the black outside (row 0), not the grey lining (row 4): %s L %.1f', identity.rep.key,
           identity.L))
    local main = plan['f931de8adf8b2386:2']
    assert(main and main.L < 32 and main.source == 'e200d7b29ba656bd:0', string.format(
           'the armor\'s main the black: %s L %.1f (the lining\'s grey gave L 37.5)', main and main.source, main and main.L))
    holder.pipeline.close()
    -- a largest color mostly on the outside stays the main: da9ebb65's navy (57%, 59% of it outside) over its red
    -- (35%, all outside but a little larger there); by outside area alone the red took the helmet and plates and the
    -- navy left the outfit (round 30, case 43)
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(GORILLA, 16), armor = tonumber(ARMOR, 16),
                body = 0, cape = tonumber(NAVY_CAPE, 16)}).action == 'apply', 'the Guerilla Gorilla under da9ebb65')
    local gplan, gs = cape_plan(holder.pipeline, NAVY_CAPE, GORILLA)
    local gid = Matcher.identity(gs)
    assert(gid.b < -20, string.format('the identity the navy: L %.1f a %.1f b %.1f', gid.L, gid.a, gid.b))
    local shell = gplan['6ede98d6c89e432a:3']
    assert(shell and shell.b < -15, string.format('the helmet\'s main the navy: %s', shell and
           string.format('L %.1f a %.1f b %.1f', shell.L, shell.a, shell.b) or 'kept'))
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: a one-color cape repaints the item\'s own accents: the I-92 Fire Fighter helmet\'s '
      .. 'orange (22%) and its small orange trim take the dark grey of Triangulation Veil (99.9% dark grey; independent '
      .. 'review 2026-10-11, case 110; the user chose "repaint for capes")', function()
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(FIRE_FIGHTER, 16),
                armor = tonumber(ARMOR, 16), body = 0, cape = tonumber(TRIANGULATION, 16)}).action == 'apply',
           'the Fire Fighter under the cape')
    local plan = cape_plan(holder.pipeline, TRIANGULATION, FIRE_FIGHTER)
    for _, key in ipairs({'544e722b0d1c0c7d:7', '544e722b0d1c0c7d:3'}) do
        local m = plan[key]
        assert(m and m.L < 40 and math.sqrt(m.a ^ 2 + m.b ^ 2) < 10, string.format('%s the cape\'s dark: %s', key,
               m and string.format('L %.1f a %.1f b %.1f', m.L, m.a, m.b) or 'kept its orange'))
    end
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: a large colored part keeps its own color only when the cape shows that color on '
      .. '10% or more, else it takes the cape\'s main: the TR-7 Ambassador of the Brand\'s cyan plates (28%) matched '
      .. 'the black cape bd961a7c\'s 5% navy hem and stayed cyan, and as a band they would take its red (independent '
      .. 'review 2026-10-11, case 120; the user chose "the cape\'s main")', function()
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(AMBASSADOR, 16),
                body = 0, cape = tonumber(HEM_CAPE, 16)}).action == 'apply', 'the Ambassador under the cape')
    local plan, s = cape_plan(holder.pipeline, HEM_CAPE, AMBASSADOR)
    local plates = plan['4df92b8a85f7d647:0']
    assert(plates and plates.source == Matcher.identity(s).rep.key and not plates.band
           and math.sqrt(plates.a ^ 2 + plates.b ^ 2) < 5, string.format('the plates the cape\'s black: %s',
           plates and string.format('%s L %.1f a %.1f b %.1f band %s', plates.source, plates.L, plates.a, plates.b,
           tostring(plates.band)) or 'kept their cyan'))
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: a color the cape shows only on its lining paints no large part: the EX-00 '
      .. 'Prototype X\'s grey dome (61%) takes Standard of Safe Distance\'s sage panel, not its taupe lining (independent '
      .. 'review 2026-10-11, case 70; the user chose "outside first" and "fix 70")', function()
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(PROTOTYPE_X, 16),
                armor = tonumber(ARMOR, 16), body = 0, cape = tonumber(SAFE_DISTANCE, 16)}).action == 'apply',
           'the Prototype X under the cape')
    local plan = cape_plan(holder.pipeline, SAFE_DISTANCE, PROTOTYPE_X)
    local dome = plan['ff5a9653e38b312d:0']
    assert(dome and dome.source == '69a56f190a9587a6:2', string.format('the dome the sage panel (row 2), not the '
           .. 'lining (row 4): %s', dome and dome.source or 'kept'))
    holder.pipeline.close()
end)

-- A cape plan of target_id under cape_id after a job loaded both, with the target item (for its pattern plan).
local function cape_case(cape_id, helmet, armor, target_id)
    holder = {}
    assert(run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(helmet, 16), armor = tonumber(armor, 16),
                body = 0, cape = tonumber(cape_id, 16)}).action == 'apply', target_id .. ' under ' .. cape_id)
    local plan, s = cape_plan(holder.pipeline, cape_id, target_id)
    local a = analysis_of(holder.pipeline, target_id)
    return plan, s, Matcher.item(a.rows, a.kit.kit_type == 'Armor', Recolor.patterns_of(a), Recolor.look_of(a, appearance))
end

check('Helmet and Armor Match Cape, the fresh gallery\'s failures (independent review 2026-10-11; the user chose to fix '
      .. 'them): a one-color cape repaints a pattern accent (37), a cape\'s second main color reaches a main part (36), '
      .. 'an undersuit takes a cape color when the cape has no dark neutral (80)', function()
    -- 37: the FS-23 Battle Master's yellow stripes (a pattern, 7.7%) take e7619545's dark grey
    local plan, s, t = cape_case(GREY_CAPE, 'a5574ac2', BATTLE_ARMOR, BATTLE_ARMOR)
    local stripes = Matcher.pattern_plan(t, s, plan)['f18dfbb5346732c1']
    assert(stripes and stripes.source == Matcher.identity(s).rep.key, 'the yellow stripes the cape\'s grey: '
           .. tostring(stripes and stripes.source))
    holder.pipeline.close()
    -- 36: the BP-32 Jackboot's light grey parts (16%) take 1264718e's yellow (37%), its black stays
    plan = cape_case(YELLOW_HALF, 'a5574ac2', JACKBOOT, JACKBOOT)
    local grey = plan['17b654674e01e40e:0']
    assert(grey and grey.source == '716e89b0d447112d:3' and grey.b > 40, 'the 16% part the yellow: '
           .. tostring(grey and grey.source))
    assert(plan['17b654674e01e40e:1'].L < 35, 'the black main stays dark')
    holder.pipeline.close()
    -- 80: the IE-3 Martyr's olive undersuit takes Federation's Embrace's blue (it kept its olive), never its own olive.
    -- v1.5: the cape has no secondary of its own (its gold, 8%, reaches the trims), so the plan stays as made; a drab of
    -- the gold read as a brown jumpsuit (independent review 1 2026-10-14; the user: no shade "from nowhere")
    plan = cape_case(FEDERATION, 'a5574ac2', MARTYR, MARTYR)
    local suit = plan['4d166892662fc759:3']
    assert(suit and suit.source == '6c03ec08eb2dd96a:0' and not suit.tone and suit.b < -5, 'the undersuit the cape\'s '
           .. 'blue: ' .. tostring(suit and suit.source) .. string.format(' b %.1f', suit and suit.b or 0))
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: under a black cape a part with a strongly tinted gloss floor stays a dark grey, not '
      .. 'its floor\'s tint: the FS-05 Marksman\'s red dome under Honored Heirloom (fresh gallery 2026-10-11, case 103: '
      .. 'teal, paint L 28 a -11 b -3; Colour.GLOSS_TINT_C)', function()
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(MARKSMAN, 16),
                        armor = tonumber(ARMOR, 16), body = 0, cape = tonumber(HEIRLOOM, 16)})
    assert(result.action == 'apply', 'the Marksman under the cape')
    local spec = assert(result.luts['8b2d8cca04e71271'], 'the dome\'s LUT')
    local L, a, b = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(L < 35 and a > -6 and math.sqrt(a * a + b * b) < 8, string.format('the dome a dark grey: L %.1f a %.1f b %.1f',
           L, a, b))
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: a cloth part whose goal lies under its response\'s floor keeps the goal\'s hue: '
      .. 'the UF-16 Inspector\'s red sleeve under cape 92762946\'s navy is navy, not purple (independent review '
      .. '2026-10-11, case 33: its paint L 0.8 a 4.2 b -8.6 and its detail color L 11.6 a 10.1 b -9.6; Transfer.FLOOR_TURN)',
      function()
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2,
                        armor = tonumber(INSPECTOR, 16), body = 0, cape = tonumber(SLEEVE_CAPE, 16)})
    assert(result.action == 'apply', 'the Inspector under the cape')
    local spec = assert(result.luts['e60ac22345c3e9bd'], 'the sleeve\'s LUT')
    local o = 1 * spec.width * 4 -- row 1, the red sleeve
    local L, a, b = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
    assert(L > 5 and a < 2.5 and b < -10, string.format('the sleeve\'s paint a navy: L %.1f a %.1f b %.1f', L, a, b))
    local dL, da, db = Colour.srgb_to_lab(spec.data[o + 24], spec.data[o + 25], spec.data[o + 26]) -- column 6
    assert(da < 6 and db < -10, string.format('its detail color a navy, not purple: L %.1f a %.1f b %.1f', dL, da, db))
    holder.pipeline.close()
    -- a paint turned less than FLOOR_TURN keeps its response: the CM-21 Trench Paramedic's near-black navy row (goal
    -- L 6.3 a -2.1 b -12.7 under a floor of L 14.0) turned 27 degrees, paint L 2.1 a 5.6 b -17.8 (through the model
    -- L 1.4 a 3.2 b -11.4)
    holder = {}
    result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = 0xa5574ac2,
                  armor = tonumber(PARAMEDIC_ARMOR, 16), body = 0, cape = tonumber(SLEEVE_CAPE, 16)})
    assert(result.action == 'apply', 'the Trench Paramedic under the cape')
    spec = assert(result.luts['89fde44864fafe16'], 'the Trench Paramedic\'s LUT')
    o = 1 * spec.width * 4
    L, a, b = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
    assert(b < -14, string.format('its paint through its response: L %.1f a %.1f b %.1f', L, a, b))
    holder.pipeline.close()
end)

check('Armor Matches Helmet: only a colored goal and a paint of some color count as turned under the floor '
      .. '(Transfer.FLOOR_TURN): the CW-4 Arctic Ranger\'s grey (goal L 38.5 a 0.8 b 3.1) keeps its response\'s paint '
      .. 'L 14.8 (through the model it went black), the DS-191 Scorpion\'s black paint for the AF-50 Noxious Ranger\'s tan '
      .. 'has no hue to turn', function()
    holder = {}
    local result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, helmet = 0xa5574ac2,
                        armor = tonumber(ARCTIC_RANGER, 16), body = 0})
    assert(result.action == 'apply', 'the Arctic Ranger matches the Bulwark')
    local spec = assert(result.luts['0f56021468456b5d'], 'the Arctic Ranger\'s LUT')
    local L, a, b = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(L > 10, string.format('a neutral goal keeps its response\'s paint: L %.1f a %.1f b %.1f', L, a, b))
    holder.pipeline.close()
    holder = {}
    result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, helmet = tonumber(NOXIOUS, 16),
                  armor = tonumber(ARMOR, 16), body = 0})
    assert(result.action == 'apply', 'the Scorpion matches the Noxious Ranger')
    spec = assert(result.luts['8ed9462dadec63ff'], 'the Scorpion\'s LUT')
    local o = 6 * spec.width * 4
    L, a, b = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
    -- v1.5: the fit no longer runs it to black (L 0.6) but keeps the game's darkest paint of its kind
    -- (Transfer.CLOTH_PAINT_MIN_L / GLOSSY_PAINT_MIN_L, its own when darker), in the tan's hue: no turn either
    local hue = math.deg(math.atan2(b, a))
    assert(L >= 12 and L < 25 and hue > 40 and hue < 100, string.format(
           'a paint at the floor in the goal\'s hue keeps its response\'s: L %.1f a %.1f b %.1f', L, a, b))
    holder.pipeline.close()
end)

check('Helmet Matches Armor: the white CW-36 Winter Warrior and CM-21 Trench Paramedic helmets on the black B-01 '
      .. 'Tactical take its matte finish and a charcoal of their own, not a flat black (user 2026-10-09: "way too dark '
      .. 'relative to the armor")', function()
    for _, case in ipairs({{WINTER_WARRIOR, '2f6bf4f9f826aab2'}, {PARAMEDIC_HELMET, '347f9ec7e058c863'}}) do
        holder = {}
        local result = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = false, helmet = tonumber(case[1], 16),
                            armor = tonumber(B01_ARMOR, 16), body = 0})
        local spec = assert(result.luts and result.luts[case[2]], case[1] .. ': its shell LUT rebuilt')
        local L = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
        assert(L > 15 and L < 35 and spec.data[40] >= 0.6, string.format('%s shell: base L %.1f, roughness %.2f', case[1],
               L, spec.data[40]))
        holder.pipeline.close()
    end
end)

check('Helmet Matches Armor: the IX-VOIDWALKER\'s navy band takes a dark red from the RE-1861 Parade Commander, '
      .. 'not its black (user 2026-10-09: "has accent that turns pitch black on multiple armors"; agreed: a dark '
      .. 'accent tint)', function()
    holder = {}
    local result = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = false, helmet = tonumber(VOIDWALKER, 16),
                        armor = tonumber(PARADE, 16), body = 0})
    assert(result.action == 'apply', 'the IX-VOIDWALKER from the Parade Commander')
    local p = holder.pipeline
    local h, a = analysis_of(p, VOIDWALKER), analysis_of(p, PARADE)
    local t = Matcher.item(h.rows, false, Recolor.patterns_of(h), Recolor.look_of(h, appearance))
    local s = Matcher.item(a.rows, true, Recolor.patterns_of(a), Recolor.look_of(a, appearance))
    -- (since 2026-10-10 the accent's paint itself, L 34: a band is a coat of the armor's own paint)
    local band = Matcher.plan(t, s)['a8ca62ca9574d0ac:1']
    assert(band and band.L < 40 and math.sqrt(band.a ^ 2 + band.b ^ 2) > 15 and band.a > 0,
           string.format('the band a dark red: L %.1f a %.1f b %.1f', band.L, band.a, band.b))
    local spec = assert(result.luts['a8ca62ca9574d0ac'], 'the helmet\'s LUT rebuilt')
    local o = 1 * spec.width * 4
    local L, ba, bb = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
    assert(ba > 8 and math.sqrt(ba * ba + bb * bb) > 10, string.format('its LUT row red, not black: L %.1f a %.1f b %.1f',
           L, ba, bb))
    p.close()
    -- a yellow accent: the B-01 Tactical's lemon itself (image review 2026-10-09: "expected the armor's bright lemon
    -- yellow"; a darker shade read olive-khaki, then turned toward bronze, orange: user 2026-10-10, "should be
    -- yellow"); its shell's grey scuffs follow it to black (they read as grime). The band is a coat of the armor's own
    -- yellow paint (user 2026-10-10: "01 Voidwalker's accenting doesn't match the armor's own accenting": fitted
    -- through its response, its base went to L 96 and its detail colors lime and light grey, a pale butter yellow)
    holder = {}
    local b01_result = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = false, helmet = tonumber(VOIDWALKER, 16),
                            armor = tonumber(B01_ARMOR, 16), body = 0})
    p = holder.pipeline
    local b = analysis_of(p, B01_ARMOR)
    local sb = Matcher.item(b.rows, true, Recolor.patterns_of(b), Recolor.look_of(b, appearance))
    local lemon = Matcher.plan(t, sb)['a8ca62ca9574d0ac:1']
    -- its yellow accent is a pattern (the shoulders' decal): its texel color is the paint
    assert(lemon.band and math.abs(lemon.L - 64.8) < 0.1 and math.abs(lemon.a + 8.8) < 0.1
           and math.abs(lemon.b - 55.7) < 0.1,
           string.format('the B-01\'s yellow paint: L %.1f a %.1f b %.1f', lemon.L, lemon.a, lemon.b))
    local shell_lut = assert(b01_result.luts['a8ca62ca9574d0ac'], 'the helmet\'s LUT')
    local o = 1 * shell_lut.width * 4
    for _, column in ipairs({2, 5, 6}) do
        for ch = 0, 2 do
            assert(shell_lut.data[o + column * 4 + ch] == shell_lut.data[o + ch],
                   'the band\'s column ' .. column .. ' takes its base: one coat')
        end
    end
    local yL, ya, yb = Colour.srgb_to_lab(shell_lut.data[o], shell_lut.data[o + 1], shell_lut.data[o + 2])
    local y_hue = math.deg(math.atan2(yb, ya))
    assert(yL > 60 and yL < 70 and y_hue > 94 and y_hue < 104 and math.sqrt(ya * ya + yb * yb) > 50,
           string.format('the band\'s base the armor\'s yellow (L 65 a -9 b 56), not a pale L 96: L %.1f a %.1f b %.1f',
                         yL, ya, yb))
    local dL = Colour.srgb_to_lab(shell_lut.data[8], shell_lut.data[9], shell_lut.data[10])
    assert(dL < 25, string.format('the shell\'s grey detail color dark too: L %.1f', dL))
    -- the shell turned black takes the B-01's matte black finish: at its own gloss (0.20) its scuffs read as a
    -- grey-white marbled grime (independent image reviews 2026-10-09, rounds 12 to 15; Transfer.DARK_L) ...
    assert(shell_lut.data[40] >= 0.6, string.format('the shell\'s roughness: %.2f', shell_lut.data[40]))
    -- ... and its own color carries the B-01's charcoal, not black (user 2026-10-09: matte helmets on the B-01 "way
    -- too dark relative to the armor")
    local sL = Colour.srgb_to_lab(shell_lut.data[0], shell_lut.data[1], shell_lut.data[2])
    assert(sL > 15 and sL < 35, string.format('the shell\'s base: L %.1f', sL))
    p.close()
    -- an armor without a visible accent: the band takes the hue of its most colorful part (the Enforcer's dark red)
    holder = {}
    run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = false, helmet = tonumber(VOIDWALKER, 16),
         armor = tonumber(ENFORCER, 16), body = 0})
    p = holder.pipeline
    local e = analysis_of(p, ENFORCER)
    local se = Matcher.item(e.rows, true, Recolor.patterns_of(e), Recolor.look_of(e, appearance))
    local red = Matcher.plan(t, se)['a8ca62ca9574d0ac:1']
    assert(red.L < 30 and red.a > 8 and math.sqrt(red.a ^ 2 + red.b ^ 2) > 10,
           string.format('a dark red band on the Enforcer: L %.1f a %.1f b %.1f', red.L, red.a, red.b))
    p.close()
end)

check('Helmet Matches Armor: a white glossy B-01 Tactical helmet keeps the CM-14 Physician\'s grey as its paint, not a '
      .. 'near-black under its gloss (user 2026-10-10: "some helmets\' gray is rendering as slightly darker than their '
      .. 'respective armors"; gallery case 08 read glossy black beside the grey plates)', function()
    holder = {}
    local result = run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = false, helmet = tonumber(WHITE_B01, 16),
                        armor = tonumber(PHYSICIAN, 16), body = 0})
    assert(result.action == 'apply', 'the B-01 Tactical helmet from the CM-14 Physician')
    local spec = assert(result.luts['65b4e28963cf654b'], 'the helmet\'s LUT rebuilt')
    local L = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(L > 28 and L < 42, string.format('the shell\'s paint about the plates\' grey (L 36.8), not L 15: L %.1f', L))
    holder.pipeline.close()
end)

check('Helmet and Armor Match Cape: the B-22 Model Citizen\'s chrome guards under a black cape take one dark chrome paint, '
      .. 'none near black (user 2026-10-10: "the shinguards turning pitch black", "some of the armor pieces on that set '
      .. 'have the same problem": by kept lightness differences their dimmest rows were asked L 6 and got paint L 39)',
      function()
    holder = {}
    local result = run({mode = Recolor.CAPE_SOURCE, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                        armor = tonumber(MODEL_CITIZEN, 16), body = 0, cape = tonumber(BLACK_CAPE, 16)})
    assert(result.action == 'apply', 'the B-22 Model Citizen under the cape 4100af4b')
    local lo, hi = math.huge, -math.huge
    for _, key in ipairs({'a32ee0a58b120cc2:0', 'a32ee0a58b120cc2:1', '3d1d5c7230003a11:5', '577892dab797373e:1',
                          '577892dab797373e:4'}) do
        local lut, r = key:match('^(%x+):(%d+)$')
        local spec = assert(result.luts[lut], key .. ': its LUT rebuilt')
        local o = tonumber(r) * spec.width * 4
        local L = Colour.srgb_to_lab(spec.data[o], spec.data[o + 1], spec.data[o + 2])
        lo, hi = math.min(lo, L), math.max(hi, L)
    end
    assert(lo > 44 and hi - lo < 6, string.format('the chrome rows\' paint L %.1f to %.1f (one paint, not L 39)', lo, hi))
    holder.pipeline.close()
end)

check('Armor Matches Helmet: the SC-30 Trailblazer Scout\'s coat takes the AF-50 Noxious Ranger mask\'s olive as seen, '
      .. 'its highlights apart, not a pale grey (user 2026-10-10: "The armor was much lighter tint than the helmet\'s '
      .. 'green"; the mask\'s look, L 44.8 chroma 6, counted its gloss as color)', function()
    holder = {}
    local result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = false, helmet = tonumber(NOXIOUS, 16),
                        armor = tonumber(TRAILBLAZER, 16), body = 0})
    assert(result.action == 'apply', 'the SC-30 Trailblazer Scout from the AF-50 Noxious Ranger')
    local spec = assert(result.luts['3567d86f5a9c89a6'], 'the coat\'s LUT rebuilt')
    local L, a, b = Colour.srgb_to_lab(spec.data[0], spec.data[1], spec.data[2])
    assert(L > 34 and L < 44 and b > 5 and a < 0, string.format('the coat a darker olive (the mask\'s paint L 43.6 '
           .. 'a -4.2 b 9.9), not a pale grey (L 47 before): L %.1f a %.1f b %.1f', L, a, b))
    -- its tint fitted through its warm response (Transfer.NEUTRAL_GOAL_C): a greener paint, not the goal's hue 105
    -- that rendered khaki (hue 92 against the mask's 114)
    local hue = math.deg(math.atan2(b, a))
    assert(hue > 112, string.format('the coat\'s paint hue %.0f, compensating its warm response', hue))
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

check('the SEAF scheme (user request 2026-10-09): the SEAF troopers\' uniform LUT, read from their package archive; '
      .. 'its blue the primary, its grey uniform the secondary, its black gear the cloth; parts take them by material '
      .. 'and piece', function()
    holder = {}
    local seaf_index
    for i, scheme in ipairs(Schemes.LIST) do if scheme.id == 'seaf' then seaf_index = i end end
    local seaf = Schemes.LIST[seaf_index]
    local result = run({mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0,
                        scheme = seaf_index})
    assert(result.action == 'apply' and result.first == 0 and result.last == 9 and result.key:find('^scheme:seaf:'),
           'both items from the SEAF scheme')
    local p = holder.pipeline
    local lut = assert(p.schemes[seaf.lut], 'the SEAF LUT read from ' .. seaf.archive)
    assert(lut.width == 23 and lut.height == 8, 'a 23 x 8 LUT')
    local colour = p.model()
    local s = Schemes.item(Matcher, Colour, colour, seaf, lut)
    local blue, uniform, gear = s.groups[1], s.groups[2], s.groups[3]
    -- a slate blue, not periwinkle or lilac; a mid-grey uniform (independent image review 2026-10-09: "a greyer slate
    -- blue", the uniform "near-white")
    local hue = math.deg(math.atan2(blue.b, blue.a)) % 360
    assert(blue.rep.key == seaf.lut .. ':2' and blue.L > 29 and blue.L < 35 and hue > 260 and hue < 280
           and math.sqrt(blue.a ^ 2 + blue.b ^ 2) < 14,
           string.format('primary the SEAF blue: L %.1f a %.1f b %.1f', blue.L, blue.a, blue.b))
    assert(uniform.rep.key == seaf.lut .. ':1' and uniform.L > 37 and uniform.L < 43
           and math.sqrt(uniform.a ^ 2 + uniform.b ^ 2) < 1 and gear.rep.key == seaf.lut .. ':3' and gear.L < 23,
           'secondary the grey uniform, cloth the black gear')
    -- the Bulwark: its steel takes the blue
    local helmet = analysis_of(p, HELMET)
    local t = Matcher.item(helmet.rows, false, Recolor.patterns_of(helmet), Recolor.look_of(helmet, appearance))
    local plan = Matcher.plan(t, s)
    assert(plan[t.groups[1].rows[1].key].source == blue.rep.key, 'the helmet\'s main part SEAF blue')
    local keys = Schemes.role_keys(seaf)
    local BLUE, UNIFORM, GEAR = keys[1], keys[2], keys[3]
    local function role_plan_of(id)
        local item = analysis_of(p, id)
        local tt = Matcher.item(item.rows, item.kit.kit_type == 'Armor', Recolor.patterns_of(item),
                                Recolor.look_of(item, appearance))
        return Schemes.role_plan(Matcher, tt, s, keys), tt
    end
    local function roles_of(id)
        local rp, tt = role_plan_of(id)
        return function(i) return rp[tt.groups[i].rows[1].key] end, rp
    end
    local bulwark = roles_of(HELMET)
    assert(bulwark(1).source == BLUE and bulwark(1).finish == BLUE, 'the Bulwark\'s steel painted SEAF blue')
    local scorpion, scorpion_plan = roles_of(ARMOR)
    assert(scorpion(1).source == UNIFORM and scorpion(1).L > 35, 'the Scorpion\'s cloth shell the grey uniform')
    assert(scorpion(2).source == GEAR and scorpion(2).L < 26, 'its dark undersuit the black gear')
    assert(scorpion(3).source == BLUE, 'its hard pads the SEAF blue')
    -- the vest's cloth (soft rows of its torso armor piece) is gear: the troopers' black vest (review 2026-10-09: "the
    -- old vest area should be black")
    assert(scorpion_plan['a007a73e4082430e:3'].source == GEAR, 'the Scorpion\'s vest cloth black')
    -- and black in the built LUT: its brown cloth sheen (column 12) neutral too (round 8 renders: the vest read brown)
    local vest = assert(result.luts['a007a73e4082430e'], 'the vest\'s LUT rebuilt')
    for _, r in ipairs({2, 3, 5}) do
        local o = (r * vest.width + 12) * 4
        local _, sa, sb = Colour.srgb_to_lab(vest.data[o], vest.data[o + 1], vest.data[o + 2])
        assert(math.sqrt(sa * sa + sb * sb) < 1, string.format('vest row %d sheen neutral: a %.1f b %.1f', r, sa, sb))
    end
    -- flat role colors: every role entry follows its role's hue, offsets within 6, every color of the row (all); the
    -- uniform fits through its response, hue included (src/transfer.lua neutral_goal), the blue and the gear as paint
    -- (no response: one albedo on every armor; through responses measured on black plastic plates overshot to a pale
    -- blue, round 9 review)
    local uniform_cal = false
    for key, m in pairs(scorpion_plan) do
        local src = m.source == BLUE and blue or m.source == UNIFORM and uniform or gear
        assert(m.all and m.a == src.a and m.b == src.b and math.abs(m.L - src.L) <= 6 + 1e-9, 'flat: ' .. key)
        uniform_cal = uniform_cal or (m.source == UNIFORM and m.cal ~= nil)
        if m.source == GEAR then assert(m.cal == nil, 'gear as paint: ' .. key) end
        if m.source == BLUE then assert(m.cal == nil, 'blue as paint: ' .. key) end
    end
    assert(uniform_cal, 'the uniform through its rows\' responses')
    local function shares(id)
        local rp, tt = role_plan_of(id)
        local by = {[BLUE] = 0, [UNIFORM] = 0, [GEAR] = 0}
        for _, row in ipairs(tt.rows) do
            local m = rp[row.key]
            if m and not row.lens then by[m.source] = by[m.source] + row.area / tt.paint_area end
        end
        return by, rp
    end
    local sc = shares(ARMOR)
    assert(sc[BLUE] > 0.15 and sc[UNIFORM] > 0.35 and sc[GEAR] > 0.3, string.format(
           'the Scorpion: blue %.2f, uniform %.2f, gear %.2f', sc[BLUE], sc[UNIFORM], sc[GEAR]))
    run({mode = Recolor.OFF, keep_sets = true, helmet = tonumber(B01_HELMET, 16), armor = tonumber(B01_ARMOR, 16),
         body = 0, scheme = seaf_index})
    -- an all-black armor: its black plates the blue, each undergarment LUT's clearly largest cloth the uniform (jacket,
    -- trousers), its other cloth gear: the gloves stay black (review 2026-10-09: "the gloves turn white")
    local b01, b01_plan = shares(B01_ARMOR)
    assert(b01[BLUE] > 0.3 and b01[UNIFORM] > 0.2 and b01[GEAR] > 0.25, string.format(
           'the B-01 Tactical: plates blue %.2f, cloth %.2f, gear %.2f', b01[BLUE], b01[UNIFORM], b01[GEAR]))
    assert(b01_plan['a0d85b3a43ec0caa:0'].source == UNIFORM and b01_plan['f645a74066cfb65f:0'].source == UNIFORM,
           'the B-01\'s jacket and trousers the uniform')
    assert(b01_plan['a0d85b3a43ec0caa:2'].source == GEAR, 'the B-01\'s gloves black')
    -- colored trims and stripes take the gear black whatever their material (SEAF's trim is black)
    for _, id in ipairs({ARMOR, B01_ARMOR}) do
        local rp, tt = role_plan_of(id)
        local accents = 0
        for _, g in ipairs(tt.groups) do
            if math.sqrt(g.ma * g.ma + g.mb * g.mb) >= 20 and g.share < 0.10 then
                accents = accents + 1
                assert(rp[g.rows[1].key].source == GEAR, 'a colored trim the gear black')
            end
        end
        assert(accents > 0, id .. ' has a colored trim')
    end
    -- an armor with light cloth and plates of its own: its dark parts are gear (review 2026-10-09: the PH-9 Predator's
    -- boots white and its gloves blue; the troopers' are black)
    run({mode = Recolor.OFF, keep_sets = true, helmet = tonumber(B01_HELMET, 16), armor = tonumber(PREDATOR, 16),
         body = 0, scheme = seaf_index})
    local _, predator = shares(PREDATOR)
    assert(predator['39bb5a8f3130b0f4:3'].source == GEAR, 'the Predator\'s boots black')
    assert(predator['199d74422bd178b8:2'].source == GEAR, 'its dark glove part black')
    assert(predator['39bb5a8f3130b0f4:2'].source == UNIFORM and predator['3b41a34df833c650:2'].source == UNIFORM,
           'its camo trousers and shirt the uniform')
    assert(predator['42bdcdede3a86d07:0'].source == BLUE and predator['07c5ef7bd9b73f76:0'].source == BLUE,
           'its camo plates the blue')
    -- the CM-21 Trench Paramedic (review 2026-10-09: white boots, a red visor, a striped pouch)
    local result_medic = run({mode = Recolor.OFF, keep_sets = true, helmet = tonumber(PARAMEDIC_HELMET, 16),
                              armor = tonumber(PARAMEDIC_ARMOR, 16), body = 0, scheme = seaf_index})
    local _, medic = shares(PARAMEDIC_ARMOR)
    -- (the Twigsnapper check follows the Paramedic's)
    assert(medic['c6f5e2827a6c95bc:3'].source == GEAR and medic['c6f5e2827a6c95bc:5'].source == GEAR,
           'the Paramedic\'s boots black')
    assert(medic['c6f5e2827a6c95bc:0'].source == UNIFORM and medic['2c4777a91d98cf95:0'].source == UNIFORM,
           'its suit the uniform')
    assert(medic['417485d7a718bff3:6'].source == GEAR and medic['417485d7a718bff3:5'].source == GEAR,
           'its pouch black')
    local medic_helmet = role_plan_of(PARAMEDIC_HELMET)
    local visor = assert(medic_helmet['347f9ec7e058c863:7'], 'the red visor (a lens) planned')
    assert(visor.L <= 28 and visor.a == 0 and visor.b == 0 and visor.all and not visor.cal, 'a dark neutral smoke')
    local glass = assert(result_medic.luts['347f9ec7e058c863'], 'the visor\'s LUT rebuilt')
    local o = 7 * glass.width * 4
    local _, va, vb = Colour.srgb_to_lab(glass.data[o], glass.data[o + 1], glass.data[o + 2])
    assert(math.sqrt(va * va + vb * vb) < 3, string.format('the visor glass neutral: a %.1f b %.1f', va, vb))
    -- the SA-12 Twigsnapper (round 9 review): its trousers, the largest cloth of its legs' mask (34% against 20%) but
    -- near-equal on screen behind its plates, the uniform; its camo plates plain blue, the light grey base between
    -- the camo colors (0.77) blue too
    local result_twig = run({mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = tonumber(TWIGSNAPPER, 16),
                             body = 0, scheme = seaf_index})
    local _, twig = shares(TWIGSNAPPER)
    assert(twig['77b946bd91b3fed2:0'].source == UNIFORM and twig['77b946bd91b3fed2:1'].source == GEAR,
           'the Twigsnapper\'s trousers grey, the next cloth black')
    assert(twig['88dea8b07355e19e:0'].source == BLUE, 'its camo plates blue')
    local plates = assert(result_twig.luts['88dea8b07355e19e'], 'its plates\' LUT rebuilt')
    local base_L, base_a, base_b = Colour.srgb_to_lab(plates.data[0], plates.data[1], plates.data[2])
    local base_hue = math.deg(math.atan2(base_b, base_a)) % 360
    assert(base_L < 60 and base_hue > 240 and base_hue < 300 and math.sqrt(base_a ^ 2 + base_b ^ 2) > 4,
           string.format('the camo base blue, not a light grey: L %.1f a %.1f b %.1f', base_L, base_a, base_b))
    p.close()
    -- the job plans SEAF by material: the same request planned by area and lightness gives other colors
    local saved = Schemes.role_plan
    Schemes.role_plan = function(_, t2, s2) return Matcher.plan(t2, s2) end
    holder = {}
    local by_area = run({mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0,
                         scheme = seaf_index})
    Schemes.role_plan = saved
    holder.pipeline.close()
    local differ = 0
    for name, spec in pairs(result.luts) do
        local other = by_area.luts[name]
        for i = 0, spec.width * spec.height * 4 - 1 do
            if not other or other.data[i] ~= spec.data[i] then differ = differ + 1 end
        end
    end
    assert(differ > 0, 'the job uses the material roles')
end)

-- A patch file (classic archive) in PATCHES holding resources ({name, type, main, gpu, stream} as Lua strings; gpu
-- and stream may be absent), each part after the previous resource's in its file.
local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
                                          math.floor(v / 16777216) % 256) end
local function le64(hex) return le32(tonumber(hex:sub(9, 16), 16)) .. le32(tonumber(hex:sub(1, 8), 16)) end
local function write_patch(file, resources)
    local main_at, stream_at, gpu_at = 72 + 32 + 80 * #resources, 0, 0
    local toc, mains, streams, gpus = {}, {}, {}, {}
    for i, r in ipairs(resources) do
        local stream, gpu = r.stream or '', r.gpu or ''
        toc[i] = le64(r.name) .. le64(r.type) .. le32(main_at) .. le32(0) .. le32(stream_at) .. le32(0) .. le32(gpu_at)
            .. le32(0) .. string.rep('\0', 16) .. le32(#r.main) .. le32(#stream) .. le32(#gpu) .. string.rep('\0', 12)
        mains[i], streams[i], gpus[i] = r.main, stream, gpu
        main_at, stream_at, gpu_at = main_at + #r.main, stream_at + #stream, gpu_at + #gpu
    end
    local out = assert(io.open(PATCHES .. file, 'wb'))
    out:write(le32(0xF0000011), le32(1), le32(#resources), string.rep('\0', 60), string.rep('\0', 32),
              table.concat(toc), table.concat(mains))
    out:close()
    out = assert(io.open(PATCHES .. file .. '.gpu_resources', 'wb'))
    out:write(table.concat(gpus))
    out:close()
    out = assert(io.open(PATCHES .. file .. '.stream', 'wb'))
    out:write(table.concat(streams))
    out:close()
end
local function write_texture_patch(file, name, main, gpu, stream)
    write_patch(file, {{name = name, type = Kits.TYPE_TEXTURE, main = main, gpu = gpu, stream = stream}})
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
    -- no part's bytes enter the patch signature (v1.4: entries only), so only the analyses' content hashes of the
    -- bytes they read can see an equal-size change; padding past what the LUT read never counts
    gpu = gpu .. string.rep('\0', 65536 + 4096 - #gpu)
    -- a color change (the base color red): the response is kept, the archived row recorded
    local red = poke(gpu, largest.row, 0, 0, '\0\60\0\0\0\0')
    local a, row, item_row = analyse_with(red, cache)
    assert(row.finish_changed == false and row.vanilla and math.abs(row.vanilla.L - largest.L) < 1e-9,
           'a color-only change, its archived color recorded')
    assert(not a.geometry_patched and item_row.cal ~= nil, 'still measured, through its response')
    assert(a.patch_deps and #a.patch_deps == 1 and a.patch_deps[1].name == LUT
           and a.patch_deps[1].hash:match('^%d+:%x+$'), 'the patched LUT and its content hash recorded')
    -- only what the analysis read: the DDS header and mip 0 (23 x 8 halves), not the padding after it
    assert(a.patch_deps[1].ranges == string.format('main:0+%d|gpu:0+1472', #main)
           and a.patch_deps[1].hash:match('^(%d+):') == tostring(#main + 1472), 'the ranges read: ' .. a.patch_deps[1].ranges)
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

-- The colors a result writes: base color (column 0 RGB) of every LUT row and texel 0 of every pattern, by
-- 'lut:row' / 'pattern:name'.
local function written(result)
    local out = {}
    for name, spec in pairs(result.luts) do
        if not spec.sheet then
            for r = 0, spec.height - 1 do
                local at = r * spec.width * 4
                out[name .. ':' .. r] = {spec.data[at], spec.data[at + 1], spec.data[at + 2]}
            end
        end
    end
    for name, spec in pairs(result.patterns or {}) do out['pattern:' .. name] = {spec.data[0], spec.data[1], spec.data[2]} end
    return out
end

check('another mod\'s patch to an armor\'s geometry keeps the rows no kit shows out of its colors (end user 2026-10-08: '
      .. 'a patched CE-27 Ground Breaker gave every helmet\'s stripes the pure green of a hidden debug row)', function()
    local DEBUG_LUT = '19a4fb2cd5670ff2' -- a Ground Breaker accessory's: rows 2-6 debug colors, row 2 pure green
    local helmets = {GRENADIER, CONSTRICTOR, HELMET}
    local function request(h)
        return {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, keep_hoods = false, materials = true,
                helmet = tonumber(h, 16), armor = tonumber(GROUND_BREAKER, 16), body = 0}
    end
    clear_patches()
    deps.cache_path = root .. '/build/test-job-geometry.cache'
    os.remove(deps.cache_path)
    holder = {}
    local measured = {}
    for _, h in ipairs(helmets) do measured[h] = written(run(request(h))) end
    local armor = analysis_of(holder.pipeline, GROUND_BREAKER)
    local shared = holder.pipeline.samples.archive
    local mask
    for _, entry in ipairs(armor.pieces) do
        for _, m in ipairs(entry.materials) do
            if m.lut == DEBUG_LUT and m.mask then mask = mask or m.mask end
        end
    end
    assert(not armor.geometry_patched and mask, 'vanilla: measured; the debug LUT\'s material has an ID mask')
    holder.pipeline.close()
    -- the mod: that very piece's ID mask served from a patch, unchanged (the worst case: the patched piece is the one
    -- whose hidden rows texture coverage counts)
    local slim = Slim.open(Files.new(game_root .. '/data/'), '')
    local kit
    for _, k in ipairs(chosen) do if k.id == GROUND_BREAKER then kit = k end end
    local archive, record
    for _, a in ipairs({kit.archive, shared}) do
        record = slim.locate(a, mask, Kits.TYPE_TEXTURE)
        if record then archive = a break end
    end
    assert(record, 'the ID mask in the game data')
    local function part(name)
        local size = slim.part_size(record, name)
        local out = ffi.new('uint8_t[?]', math.max(size, 1))
        if size > 0 then slim.part(archive, record, name, 0, size, out, 0) end
        return ffi.string(out, size)
    end
    write_texture_patch('9ba626afa44a3aa3.patch_0', mask, part('main'), part('gpu'), part('stream'))
    slim.close()
    holder = {}
    for _, h in ipairs(helmets) do
        local now = written(run(request(h)))
        for key, c in pairs(now) do
            assert(not (c[2] > 0.8 and c[1] < 0.2 and c[3] < 0.2),
                   string.format('%s: no debug green written (%.3f %.3f %.3f)', key, c[1], c[2], c[3]))
            -- the colored parts (the report's stripes: the armor's yellow accent) as the measured plan paints them;
            -- neutral parts may pair with another of the armor's greys (texture coverage weighs the parts, not pixels)
            local before = measured[h][key]
            local L1, a1, b1 = Colour.srgb_to_lab(before and before[1] or 0, before and before[2] or 0,
                                                  before and before[3] or 0)
            -- light ones colored in both plans: a part may pair with another color by texture coverage than by pixels
            -- and take the accent in one plan only (src/matcher.lua tint_bands: a colored part paired with a neutral;
            -- the CE-64 Grenadier's row 0 pairs with the patched armor's beige), but never a third color (debug green)
            local L2, a2, b2 = Colour.srgb_to_lab(c[1], c[2], c[3])
            if before and math.sqrt(a1 * a1 + b1 * b1) > 30 and L1 >= 40 and math.sqrt(a2 * a2 + b2 * b2) > 30 then
                local de = Colour.de2000(L1, a1, b1, L2, a2, b2)
                assert(de < 3, string.format('%s with %s: %.1f from the measured plan\'s color (L %.1f a %.1f b %.1f, '
                       .. 'now L %.1f a %.1f b %.1f)', h, key, de, L1, a1, b1, L2, a2, b2))
            end
        end
    end
    assert(analysis_of(holder.pipeline, GROUND_BREAKER).geometry_patched, 'the mask from the patch: geometry patched')
    holder.pipeline.close()
    clear_patches()
    os.remove(deps.cache_path)
    deps.cache_path = CACHE
end)

-- v1.5 (end user 2026-10-14: the Cowboy Hat mod "doesn't work"): a mod that gives a helmet a material without a color
-- table, its colors in its albedo (src/albedo.lua). The test writes its own such mod, never a third-party file: the
-- CPR-80 Bulwark helmet's units with every material replaced by one material of the character template whose albedo
-- (256 x 256 BC1, 9 mips) holds leather, a dark band, a silver badge that is metal (the mra's red) and a transparent
-- brim.
local HAT_MATERIAL, HAT_ALBEDO, HAT_MRA = 'ab5e000000000001', 'ab5e000000000002', 'ab5e000000000003'
local function hat_mod(albedo_format)
    local u8 = ffi.new('uint8_t[?]', 8)
    local function block(c0, c1, idx)
        u8[0], u8[1], u8[2], u8[3] = c0 % 256, math.floor(c0 / 256), c1 % 256, math.floor(c1 / 256)
        for k = 0, 3 do u8[4 + k] = math.floor(idx / 256 ^ k) % 256 end
        return ffi.string(u8, 8)
    end
    local function rgb565(r, g, b)
        return math.floor(r * 31 / 255 + 0.5) * 2048 + math.floor(g * 63 / 255 + 0.5) * 32 + math.floor(b * 31 / 255 + 0.5)
    end
    local leather, band, badge = rgb565(104, 72, 40), rgb565(30, 30, 35), rgb565(160, 160, 165)
    local albedo, mra, seed = {}, {}, 7
    for m = 0, 8 do
        local side = math.max(1, 64 / 2 ^ m)
        for i = 0, side * side - 1 do
            local row = math.floor(i / side) * 64 / side -- mip 0's block row
            seed = (seed * 16807) % 2147483647
            local idx = seed % 4294967296
            local c, metal = leather, m == 0 and row >= 56 and row < 60
            if m == 0 and row >= 40 and row < 56 then c = band end
            if metal then c = badge end
            if m == 0 and row >= 60 then
                albedo[#albedo + 1] = block(0, 0xFFFF, 0xFFFFFFFF) -- 3-color, transparent
            else
                albedo[#albedo + 1] = block(c, c - 32, idx) -- 4-color, one green step apart
            end
            mra[#mra + 1] = string.rep('\0', 8) .. block(metal and 0xF800 or 0, metal and 0xF800 or 0, 0)
        end
    end
    local function dds(format, mips)
        local head = ffi.new('uint8_t[?]', 0xC0 + 148)
        local function put(at, v) for k = 0, 3 do head[at + k] = math.floor(v / 256 ^ k) % 256 end end
        put(0xC0, 0x20534444) put(0xC0 + 12, 256) put(0xC0 + 16, 256) put(0xC0 + 28, mips) put(0xC0 + 84, 0x30315844)
        put(0xC0 + 128, format) put(0xC0 + 140, 1)
        return ffi.string(head, 0xC0 + 148)
    end
    local material = ffi.new('uint8_t[?]', 136 + 24)
    local function put(at, v) for k = 0, 3 do material[at + k] = math.floor(v / 256 ^ k) % 256 end end
    put(24, 0x08e0ec50) put(28, 0x7712ee78) -- the character template, content/art_shared/base_shaders/character
    put(64, 2) put(136, deps.Albedo.SLOT_ALBEDO) put(140, deps.Albedo.SLOT_MRA)
    put(144, tonumber(HAT_ALBEDO:sub(9), 16)) put(148, tonumber(HAT_ALBEDO:sub(1, 8), 16))
    put(152, tonumber(HAT_MRA:sub(9), 16)) put(156, tonumber(HAT_MRA:sub(1, 8), 16))
    return {{name = HAT_MATERIAL, type = Kits.TYPE_MATERIAL, main = ffi.string(material, 136 + 24)},
            {name = HAT_ALBEDO, type = Kits.TYPE_TEXTURE, main = dds(albedo_format, 9),
             gpu = table.concat(albedo):rep(albedo_format == 98 and 2 or 1)}, -- BC7: 16-byte blocks
            {name = HAT_MRA, type = Kits.TYPE_TEXTURE, main = dds(77, 9), gpu = table.concat(mra)}}
end

-- The helmet's units from the game data with every material in their material map made the hat's.
local function hat_units(shared)
    local slim = Slim.open(Files.new(game_root .. '/data/'), '')
    local kit
    for _, k in ipairs(chosen) do if k.id == HELMET then kit = k end end
    local out, done = {}, {}
    for _, piece in ipairs(kit.pieces) do
        local archive, record
        for _, a in ipairs({kit.archive, shared}) do
            record = slim.locate(a, piece.path, Kits.TYPE_UNIT)
            if record then archive = a break end
        end
        if record and not done[piece.path] then
            done[piece.path] = true
            local function part(name)
                local size = slim.part_size(record, name)
                local bytes = ffi.new('uint8_t[?]', math.max(size, 1))
                if size > 0 then slim.part(archive, record, name, 0, size, bytes, 0) end
                return bytes, size
            end
            local main, size = part('main')
            local function u32(o) return main[o] + main[o + 1] * 256 + main[o + 2] * 65536 + main[o + 3] * 16777216 end
            local at = u32(112)
            local n = u32(at)
            for i = 0, n - 1 do
                local o = at + 4 + 4 * n + 8 * i
                local low, high = tonumber(HAT_MATERIAL:sub(9), 16), tonumber(HAT_MATERIAL:sub(1, 8), 16)
                for k = 0, 3 do
                    main[o + k], main[o + 4 + k] = math.floor(low / 256 ^ k) % 256, math.floor(high / 256 ^ k) % 256
                end
            end
            local gpu, gpu_size = part('gpu')
            local stream, stream_size = part('stream')
            out[#out + 1] = {name = piece.path, type = Kits.TYPE_UNIT, main = ffi.string(main, size),
                             gpu = ffi.string(gpu, gpu_size), stream = ffi.string(stream, stream_size)}
        end
    end
    slim.close()
    assert(#out > 0, 'the helmet\'s units in the game data')
    return out
end

-- The mean CIELAB of the albedo's leather texels (mip 0 block rows 0-39 and every texel of mip 1) in a chain.
local function leather_lab(data)
    local out = ffi.new('uint8_t[64]')
    local r, g, b, n = 0, 0, 0, 0
    for i = 0, 64 * 64 + 32 * 32 - 1 do
        if i >= 64 * 64 or math.floor(i / 64) < 40 then
            deps.Albedo.color_block(data, i * 8, out, true)
            for t = 0, 15 do
                r, g, b, n = r + Colour.srgb_to_linear(out[4 * t] / 255), g + Colour.srgb_to_linear(out[4 * t + 1] / 255),
                    b + Colour.srgb_to_linear(out[4 * t + 2] / 255), n + 1
            end
        end
    end
    return Colour.linear_to_lab(r / n, g / n, b / n)
end

check('a mod\'s helmet whose material has no color table (end user 2026-10-14: the Cowboy Hat mod "doesn\'t work"): its '
      .. 'albedo gives its colors and takes the armor\'s, every mip, transparency kept; another albedo format is logged',
      function()
    clear_patches()
    deps.cache_path = root .. '/build/test-job-hat.cache'
    os.remove(deps.cache_path)
    holder = {}
    local helmet_request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719,
                            body = 0}
    run(helmet_request)
    local shared = holder.pipeline.samples.archive
    holder.pipeline.close()
    local resources = hat_units(shared)
    for _, r in ipairs(hat_mod(71)) do resources[#resources + 1] = r end
    write_patch('9ba626afa44a3aa3.patch_0', resources)
    -- Helmet Matches Armor: the hat's colors read, its albedo recolored
    holder = {}
    local result = run(helmet_request)
    local p = holder.pipeline
    local hat = analysis_of(p, HELMET)
    assert(hat.albedos and hat.albedos[HAT_ALBEDO] and #hat.albedos[HAT_ALBEDO].clusters == 3, 'three colors read')
    for _, row in ipairs(hat.rows) do -- its clusters are no patched LUT's rows (src/kits.lua mark_patched)
        assert(row.albedo and row.lut == HAT_ALBEDO and not row.finish_changed, 'only the hat\'s colors')
        -- matched as they look (the study's typical response; review renders 2026-10-14: by its albedo the B-01
        -- Tactical's jacket took L 49 for a hat that shows L 30)
        local c = hat.albedos[HAT_ALBEDO].clusters[row.row + 1]
        local L = deps.Albedo.look(Colour, c.lin[1], c.lin[2], c.lin[3])
        assert(row.L == L and (row.row ~= 0 or row.L < c.lab[1]), string.format('row %d as it looks: L %.1f, albedo L '
               .. '%.1f', row.row, row.L, c.lab[1]))
    end
    assert(result.action == 'apply', 'recolored')
    local spec = assert(result.luts[HAT_ALBEDO], 'the recolored albedo')
    assert(spec.albedo and spec.bc1 and spec.width == 256 and spec.mips == 9 and spec.size == 43704, 'its spec')
    assert(result.albedo_report and result.albedo_report:find('Mod texture ' .. HAT_ALBEDO .. ' (a material without a '
           .. 'color table): 3 colors read (', 1, true), tostring(result.albedo_report))
    local t = Matcher.item(hat.rows, false, Recolor.patterns_of(hat), Recolor.look_of(hat, appearance))
    local armor = analysis_of(p, ARMOR)
    local s = Matcher.item(armor.rows, true, Recolor.patterns_of(armor), Recolor.look_of(armor, appearance))
    local planned_goal = assert(Matcher.plan(t, s)[HAT_ALBEDO .. ':0'], 'the leather planned')
    local goal = {} -- the albedo that looks like the goal (src/albedo.lua unlook)
    goal.L, goal.a, goal.b = deps.Albedo.unlook(Colour, planned_goal.L, planned_goal.a, planned_goal.b)
    local L, a, b = leather_lab(spec.data)
    local de = math.sqrt((L - goal.L) ^ 2 + (a - goal.a) ^ 2 + (b - goal.b) ^ 2)
    assert(de < 3, string.format('the leather at its goal: %.1f (L %.1f a %.1f b %.1f, goal L %.1f a %.1f b %.1f)', de,
                                 L, a, b, goal.L, goal.a, goal.b))
    local out = ffi.new('uint8_t[64]')
    for i = 60 * 64, 64 * 64 - 1 do -- the brim stays transparent
        deps.Albedo.color_block(spec.data, i * 8, out, true)
        for k = 0, 15 do assert(out[4 * k + 3] == 0, 'transparent texel kept') end
    end
    -- Armor Matches Helmet: the hat's colors are the source
    local armor_result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, helmet = 0xa5574ac2,
                              armor = 0x0ade6719, body = 0})
    assert(armor_result.action == 'apply' and next(armor_result.luts), 'the armor recolored from the hat')
    local from_hat = 0
    local hat_item = Matcher.item(hat.rows, false, Recolor.patterns_of(hat), Recolor.look_of(hat, appearance))
    local armor_item = Matcher.item(armor.rows, true, Recolor.patterns_of(armor), Recolor.look_of(armor, appearance))
    for _, m in pairs(Matcher.plan(armor_item, hat_item)) do
        if type(m.source) == 'string' and m.source:sub(1, 16) == HAT_ALBEDO then from_hat = from_hat + 1 end
    end
    assert(from_hat > 0, 'the armor takes the hat\'s colors')
    p.close()
    -- a fresh pipeline (the analysis is not cached: the same texture)
    holder = {}
    local again = run(helmet_request)
    assert(ffi.string(again.luts[HAT_ALBEDO].data, 43704) == ffi.string(spec.data, 43704), 'the same recolor')
    holder.pipeline.close()
    -- a BC7 albedo: logged, left as it is
    clear_patches()
    resources = hat_units(shared)
    for _, r in ipairs(hat_mod(98)) do resources[#resources + 1] = r end
    write_patch('9ba626afa44a3aa3.patch_0', resources)
    holder = {}
    local bc7 = run(helmet_request)
    hat = analysis_of(holder.pipeline, HELMET)
    assert(not hat.albedos and hat.unread and hat.unread[HAT_MATERIAL], 'not read')
    assert(not (bc7.luts and bc7.luts[HAT_ALBEDO]), 'nothing made')
    assert(bc7.albedo_report == 'Mod material ' .. HAT_MATERIAL .. ' (from 9ba626afa44a3aa3.patch_0) has no color table '
           .. 'and is left as it is: albedo format 98.', tostring(bc7.albedo_report) .. ' / ' .. tostring(bc7.action))
    holder.pipeline.close()
    clear_patches()
    os.remove(deps.cache_path)
    deps.cache_path = CACHE
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

check('the catalogue reads a kit record in one read for its bodies and one a body (v1.3: one a body and a piece) and '
      .. 'gives the kit it kept while the record reads the same; a job\'s plan keys are the Adler-32 of the kits\' '
      .. 'signatures one after the other (KB match-your-colors-stress-test)', function()
    holder = {}
    run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0})
    local p = holder.pipeline
    local helmet, armor = p.kits.find(0xa5574ac2), p.kits.find(0x0ade6719)
    local read_into, reads = space.read_into, 0
    space.read_into = function(...) reads = reads + 1 return read_into(...) end
    local again = p.kits.find(0x0ade6719)
    space.read_into = read_into
    local bodies = {}
    for _, piece in ipairs(armor.pieces) do bodies[piece.body] = true end
    local count = 0
    for _ in pairs(bodies) do count = count + 1 end
    assert(again == armor and reads == 2 + count, string.format('the kit kept, %d reads for %d bodies', reads, count))
    local function adler(...)
        local a, b = 1, 0
        for _, kit in ipairs({...}) do
            local text = Kits.signature(kit)
            for i = 1, #text do
                a = (a + text:byte(i)) % 65521
                b = (b + a) % 65521
            end
        end
        return string.format('%08x', b * 65536 + a)
    end
    for _, kits in ipairs({{helmet}, {armor}, {helmet, armor}, {armor, helmet, armor}}) do
        assert(Recolor.records_sum(Kits, unpack(kits)) == adler(unpack(kits)), 'the Adler-32 of ' .. #kits .. ' kits')
    end
    Files.close_some(math.huge)
    p.close()
    local queued = Files.close_some(0)
    assert(queued > 0 and Files.held() == 0, 'the reader\'s handles queued, closed later (src/addon.lua): ' .. queued)
    assert(Files.close_some(math.huge) == 0, 'all closed')
end)

-- Every LUT and pattern of two results holds the same values (sizes and data).
local function same_luts(a, b, what)
    for _, field in ipairs({'luts', 'patterns'}) do
        local count_a, count_b = 0, 0
        for _ in pairs(a[field] or {}) do count_a = count_a + 1 end
        for name, spec in pairs(b[field] or {}) do
            count_b = count_b + 1
            local other = assert((a[field] or {})[name], what .. ': ' .. field .. ' ' .. name)
            assert(other.width == spec.width and other.height == spec.height and other.size == spec.size, what .. ' size')
            local n = spec.sheet and spec.size or spec.width * spec.height * 4
            for i = 0, n - 1 do
                assert(other.data[i] == spec.data[i], string.format('%s: %s %s value %d', what, field, name, i))
            end
        end
        assert(count_a == count_b, what .. ': ' .. field .. ' count')
    end
end

check('plans are keyed by what they depend on (the audit, rank 5): with Helmet Matches Armor a new helmet keeps the '
      .. 'cape\'s plan, a paint scheme plans each item once; the results equal a new session\'s', function()
    local cape_id = tonumber(COVER_OF_DARKNESS, 16)
    local function request(helmet, extra)
        local r = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = tonumber(helmet, 16), armor = 0x0ade6719,
                   body = 0, capes = true, cape = cape_id}
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    holder = {}
    local first = run(request(HELMET))
    local p = holder.pipeline
    local plans = #p.plan_order
    local second = run(request(HOODED))
    local CAPE_LUT = cover.pieces[1].lut
    assert(#p.plan_order == plans + 1, 'one new plan, the helmet pair\'s: ' .. (#p.plan_order - plans))
    assert(first.luts[CAPE_LUT] == second.luts[CAPE_LUT] and first.key ~= second.key, 'the cape\'s plan reused')
    plans = #p.plan_order
    local painted = run(request(HELMET, {scheme = 2}))
    assert(#p.plan_order == plans + 3, 'a scheme: helmet, armor and cape plans')
    plans = #p.plan_order
    local repainted = run(request(HOODED, {scheme = 2}))
    assert(#p.plan_order == plans + 1, 'another helmet: its plan only (armor and cape kept)')
    p.close()
    -- a new session (no plans, no cache) makes the same results
    local cache = deps.cache_path
    deps.cache_path = nil
    for _, case in ipairs({{second, request(HOODED)}, {painted, request(HELMET, {scheme = 2})},
                           {repainted, request(HOODED, {scheme = 2})}}) do
        holder = {}
        local fresh = run(case[2])
        assert(fresh.key == case[1].key, 'the same result key')
        same_luts(case[1], fresh, 'reused plans vs a new session')
        holder.pipeline.close()
    end
    deps.cache_path = cache
end)

check('a preview job marked obsolete (its preview moved on, src/addon.lua) ends at its next stage boundary: an obsolete '
      .. 'result, no plan made; the analyses it finished are kept', function()
    holder = {}
    local cache = deps.cache_path
    deps.cache_path = nil
    local request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
                     armor = tonumber(TRENCH, 16), body = 0, target = 'ui'}
    local co = coroutine.create(function() return Recolor.job(deps, holder, request, coroutine.yield) end)
    repeat assert(coroutine.resume(co)) until holder.stage and holder.stage:find('analysing kit', 1, true)
    request.obsolete = true -- the preview moved on while the helmet was analysed
    local ok, result
    repeat
        ok, result = coroutine.resume(co)
        assert(ok, tostring(result))
    until coroutine.status(co) == 'dead'
    local p = holder.pipeline
    assert(result.action == 'obsolete' and #p.plan_order == 0, 'ended before planning: ' .. tostring(result.action))
    assert(analysis_of(p, B01_HELMET) and not analysis_of(p, TRENCH), 'the helmet analysed, the armor not started')
    p.close()
    -- marked while the cape was analysed (Recolor Cape on): neither item analysed
    holder = {}
    request = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = tonumber(B01_HELMET, 16),
               armor = tonumber(TRENCH, 16), body = 0, target = 'ui', capes = true, cape = tonumber(DRAPE, 16)}
    co = coroutine.create(function() return Recolor.job(deps, holder, request, coroutine.yield) end)
    repeat assert(coroutine.resume(co)) until holder.stage == string.format('analysing kit %s', DRAPE)
    request.obsolete = true
    repeat
        ok, result = coroutine.resume(co)
        assert(ok, tostring(result))
    until coroutine.status(co) == 'dead'
    p = holder.pipeline
    assert(result.action == 'obsolete' and analysis_of(p, DRAPE) and not analysis_of(p, B01_HELMET)
           and not analysis_of(p, TRENCH), 'the cape analysed, neither item started')
    p.close()
    deps.cache_path = cache
end)

check('at most PLANS_KEPT plans are kept, the least recently used let go; one asked for again is made again, equal',
      function()
    local kept = Recolor.PLANS_KEPT
    Recolor.PLANS_KEPT = 2
    holder = {}
    local function request(helmet)
        return {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = tonumber(helmet, 16), armor = 0x0ade6719,
                body = 0}
    end
    local a = run(request(HELMET))
    local p = holder.pipeline
    run(request(HOODED))
    run(request(HELMET)) -- used again: now the most recent
    run(request(B01_HELMET))
    local count = 0
    for _ in pairs(p.plans) do count = count + 1 end
    assert(count == 2 and #p.plan_order == 2, 'two kept: ' .. count)
    assert(p.plans[p.plan_order[1]] and p.plan_order[2]:find(':', 1, true), 'order and plans agree')
    local again = run(request(HELMET))
    assert(again.luts['962a946e964ebc40'] == a.luts['962a946e964ebc40'], 'the most recently used kept')
    local hooded = run(request(HOODED)) -- let go before: made again
    holder.pipeline.close()
    Recolor.PLANS_KEPT = kept
    holder = {}
    same_luts(hooded, run(request(HOODED)), 'a plan made again')
    holder.pipeline.close()
end)

-- A texture of the game data (main and GPU parts) as an R32G32B32A32_FLOAT texture holding the same values: its DX10
-- format set to 2 and its mip chain (R16G16B16A16_FLOAT) widened to floats.
local function as_rgba32f(archive, name)
    local slim = Slim.open(Files.new(game_root .. '/data/'), '')
    local record = assert(slim.locate(archive, name, Kits.TYPE_TEXTURE), 'the archived texture ' .. name)
    local main_size = slim.part_size(record, 'main')
    local main = ffi.new('uint8_t[?]', main_size)
    slim.part(archive, record, 'main', 0, main_size, main, 0)
    local info = Texture.describe(main, main_size)
    assert(info.format == Texture.FORMAT_RGBA16F, 'an RGBA16F texture')
    local halves = ffi.new('uint8_t[?]', info.total)
    Texture.pixels(slim, archive, record, info)(0, info.total, halves, 0)
    slim.close()
    local floats = ffi.new('float[?]', info.total / 2)
    for i = 0, info.total / 2 - 1 do floats[i] = Texture.half(halves[2 * i], halves[2 * i + 1]) end
    local at = 0xC0 + 128 -- the DX10 header's format
    main[at], main[at + 1], main[at + 2], main[at + 3] = 2, 0, 0, 0
    return ffi.string(main, main_size), ffi.string(floats, info.total * 2)
end

check('a paint scheme whose LUT a mod replaced with an R32G32B32A32_FLOAT texture (user report 2026-10-08: "unsupported '
      .. 'texture format 2" for every scheme but Helldiver) recolors as from the same values in the game\'s format',
      function()
    local forest = Schemes.LIST[2]
    local request = {mode = Recolor.OFF, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0,
                     scheme = 2}
    clear_patches()
    holder = {}
    local vanilla = run(request)
    holder.pipeline.close()
    local main, gpu = as_rgba32f(forest.archive, forest.lut)
    write_texture_patch('9ba626afa44a3aa3.patch_0', forest.lut, main, gpu)
    deps.cache_path = root .. '/build/test-job-rgba32f.cache'
    os.remove(deps.cache_path)
    holder = {}
    local modded = run(request)
    local p = holder.pipeline
    assert(p.patch_status:find('1 patch files hold 1 ', 1, true), tostring(p.patch_status))
    assert(modded.action == 'apply' and modded.key == vanilla.key, 'recolored')
    local count = 0
    for name, spec in pairs(vanilla.luts) do
        local got = assert(modded.luts[name], 'LUT ' .. name)
        assert(got.width == spec.width and got.height == spec.height, 'size of ' .. name)
        for i = 0, spec.width * spec.height * 4 - 1 do
            assert(got.data[i] == spec.data[i], string.format('%s value %d: %.9g vs %.9g', name, i, got.data[i],
                   spec.data[i]))
        end
        count = count + 1
    end
    assert(count > 1, 'both items\' LUTs compared')
    p.close()
    -- a format nothing here reads (BC6H; BC1 is read since v1.5, mods' albedos): the job fails naming the texture
    -- and the mod's patch file
    os.remove(deps.cache_path)
    clear_patches()
    local at = 0xC0 + 128
    write_texture_patch('9ba626afa44a3aa3.patch_0', forest.lut, main:sub(1, at) .. le32(95) .. main:sub(at + 5), gpu)
    holder = {}
    local ok, why = pcall(run, request)
    assert(not ok and tostring(why):find('texture ' .. forest.lut .. ' (from 9ba626afa44a3aa3.patch_0): unsupported '
           .. 'texture format 95', 1, true), 'the failure names the texture and its patch: ' .. tostring(why))
    if holder.pipeline then holder.pipeline.close() end
    os.remove(deps.cache_path)
    deps.cache_path = CACHE
    clear_patches()
end)

check('a recolor mod that gives a set\'s LUTs and a shared pattern as R32G32B32A32_FLOAT textures (user ticket '
      .. '2026-10-09: on v1.3 every recolor touching the DP-11 Champion of the People failed, "unsupported texture '
      .. 'format 2") recolors the set as target, as source and under a paint scheme as from the game\'s own format',
      function()
    local SHARED_PATTERN = 'e1e99847592231e2' -- the DP-11's pattern, shared by 12 kits; the mod replaces it too
    local function request(mode, helmet, armor, scheme)
        return {mode = mode, keep_sets = true, helmet = tonumber(helmet, 16), armor = tonumber(armor, 16), body = 0,
                scheme = scheme}
    end
    local cases = {
        {'its helmet as target', request(Recolor.HELMET_FROM_ARMOR, DP11_HELMET, ARMOR)},
        {'its armor as target', request(Recolor.ARMOR_FROM_HELMET, HELMET, DP11_ARMOR)},
        {'its armor as source', request(Recolor.HELMET_FROM_ARMOR, HELMET, DP11_ARMOR)},
        {'the set under a paint scheme', request(Recolor.OFF, DP11_HELMET, DP11_ARMOR, 2)},
    }
    clear_patches()
    deps.cache_path = nil
    local vanilla = {}
    for i, case in ipairs(cases) do
        holder = {}
        vanilla[i] = run(case[2])
        assert(vanilla[i].action == 'apply', case[1] .. ': recolored without mods')
        holder.pipeline.close()
    end
    -- the mod's textures: every LUT of the set and the shared pattern, each the archived texture's values in 32-bit
    -- floats, one patch file each (as a mod manager numbers them)
    local textures, archive_of = {}, {}
    for _, kit in ipairs(chosen) do
        if kit.id == DP11_HELMET or kit.id == DP11_ARMOR then
            for _, piece in ipairs(kit.pieces) do
                if piece.lut ~= Kits.NO_LUT and not archive_of[piece.lut] then
                    textures[#textures + 1], archive_of[piece.lut] = piece.lut, kit.archive
                end
                if piece.pattern == SHARED_PATTERN then archive_of[SHARED_PATTERN] = kit.archive end
            end
        end
    end
    textures[#textures + 1] = SHARED_PATTERN
    local slim = Slim.open(Files.new(game_root .. '/data/'), '')
    for _, name in ipairs(textures) do
        if not slim.locate(archive_of[name], name, Kits.TYPE_TEXTURE) then
            archive_of[name] = Kits.SHARED_ARCHIVES[1]
        end
        assert(slim.locate(archive_of[name], name, Kits.TYPE_TEXTURE), 'the archived texture ' .. name)
    end
    slim.close()
    assert(#textures == 8, 'seven LUTs and the pattern: ' .. #textures)
    for i, name in ipairs(textures) do
        local main, gpu = as_rgba32f(archive_of[name], name)
        write_texture_patch('9ba626afa44a3aa3.patch_' .. (i - 1), name, main, gpu)
    end
    for i, case in ipairs(cases) do
        holder = {}
        local ok, modded = pcall(run, case[2])
        assert(ok, case[1] .. ': ' .. tostring(modded))
        local p = holder.pipeline
        assert(p.patch_status:find('8 patch files hold 8 ', 1, true), tostring(p.patch_status))
        local set = analysis_of(p, DP11_ARMOR) or analysis_of(p, DP11_HELMET)
        assert(set and set.patch_deps and #set.patch_deps > 0, case[1] .. ': the set analysed from the mod\'s textures')
        same_luts(modded, vanilla[i], case[1])
        p.close()
    end
    deps.cache_path = CACHE
    clear_patches()
end)

check('clothing on a piece with skin tones is recolored (user ticket 2026-10-09: "The shirt on the stomach of those '
      .. 'armors does not get colored by the mod, they stay the deafult yellow and green"): the PH-9 Predator\'s camo shirt '
      .. 'and the PH-56 Jaguar\'s are analysed and take the helmet\'s colors', function()
    clear_patches()
    deps.cache_path = nil
    -- {armor, the LUT of its piece with skin tones (no other piece uses it), its largest row on screen}
    for _, case in ipairs({{PREDATOR, '3b41a34df833c650', 2}, {JAGUAR, 'd83e84b662e81030', 2}}) do
        local armor, lut, row = case[1], case[2], case[3]
        holder = {}
        local result = run({mode = Recolor.ARMOR_FROM_HELMET, keep_sets = true, helmet = tonumber(BREAKER, 16),
                            armor = tonumber(armor, 16), body = 0})
        local a = analysis_of(holder.pipeline, armor)
        local skin_piece, rows = false, 0
        for _, entry in ipairs(a.pieces) do
            for _, m in ipairs(entry.materials) do
                if entry.skin and entry.weight > 0 and m.lut == lut then skin_piece = true end
            end
        end
        for _, r in ipairs(a.rows) do if r.lut == lut then rows = rows + 1 end end
        assert(skin_piece and rows > 0, armor .. ': the piece with skin tones holds ' .. lut .. ' and adds its rows')
        local spec = assert(result.luts[lut], armor .. ': its LUT is planned')
        local original, moved = a.luts[lut].values, {}
        for r = 0, spec.height - 1 do
            local at, d = r * spec.width * 4, 0
            for ch = 0, 2 do d = d + math.abs(spec.data[at + ch] - original[at + ch]) end
            moved[r] = d
        end
        local any = false
        for r = 0, spec.height - 1 do any = any or moved[r] > 0.05 end
        assert(any and (not row or moved[row] > 0.05), armor .. ': the clothing takes a new color')
        holder.pipeline.close()
    end
    deps.cache_path = CACHE
end)

check('a job dropped while it built its reader leaves no handle open once abandoned (the audit, rank 7: 20 abandoned '
      .. 'Slim.open calls kept 20 handles); a finished job holds none', function()
    if not pcall(ffi.typeof, 'myct_handles_declared') then
        ffi.cdef [[
            typedef struct myct_handles_declared { int unused; } myct_handles_declared;
            void *myct_GetCurrentProcess(void) __asm__("GetCurrentProcess");
            int myct_GetProcessHandleCount(void *process, uint32_t *count) __asm__("GetProcessHandleCount");
        ]]
    end
    local kernel, count = ffi.load('kernel32'), ffi.new('uint32_t[1]')
    local function handles()
        assert(kernel.myct_GetProcessHandleCount(kernel.myct_GetCurrentProcess(), count) ~= 0)
        return count[0]
    end
    holder = {}
    run({mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, helmet = 0xa5574ac2, armor = 0x0ade6719, body = 0})
    holder.pipeline.close()
    Files.close_some(math.huge) -- the closed readers' handles queued (src/addon.lua drains them on binding checks)
    assert(Files.held() == 0, 'a finished job holds no handle: ' .. Files.held())
    local before = handles()
    for _ = 1, 5 do
        local co = coroutine.create(function()
            return Slim.open(Files.new(game_root .. '/data/', nil, nil, coroutine.yield), '', coroutine.yield)
        end)
        assert(coroutine.resume(co) and coroutine.status(co) == 'suspended', 'paused inside Slim.open')
    end
    assert(Files.held() >= 5 and handles() >= before + 5, 'their files open: ' .. Files.held())
    Files.abandon()
    collectgarbage('collect') -- lint-ok: R4 test process only
    assert(Files.held() == 0 and handles() == before, string.format('closed: %d held, %d handles (was %d)', Files.held(),
           handles(), before))
end)

print('PASS test_job (' .. passed .. ' checks)')
