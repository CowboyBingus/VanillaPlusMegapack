-- Match Your Colors: Recolor Weapons (src/loadout.lua, src/weapons.lua) in the frame step, against the simulated game
-- with the inventory, weapon entities and their customization (tests/fake_game.lua Fake.weapons): off by default and
-- then free, the weapons planned and bound, the weapon in hand's reload bound again the next frame, pickups, respawns,
-- options, the Armory's weapon preview, and the exact calls each kind of frame adds (against a twin with the option
-- off; tests/frame_budget.lua). The jobs are tests/test_addon.lua's canned ones.
-- Usage: luajit tests/test_weapons.lua <repository root>
local root = assert(arg and arg[1], 'usage: test_weapons.lua <repository root>')
package.path = root .. '/src/?.lua;' .. package.path
rawset(_G, 'MYC_TEST_SETUP_ONLY', true) -- lint-ok: R8 test process only
local setup, requests, helpers = dofile(root .. '/tests/test_addon.lua')
rawset(_G, 'MYC_TEST_SETUP_ONLY', nil) -- lint-ok: R8 test process only
local Fake = dofile(root .. '/tests/fake_game.lua')
local Recolor = require('recolor')
local budget = dofile(root .. '/tests/frame_budget.lua')
local passed = 0
local function check(name, fn)
    fn()
    passed = passed + 1
end
local same = helpers.same

-- The weapons: an AR-23 Liberator (its unit and two attachment units, each with a LUT of its own), a P-2 Peacemaker
-- and, picked up later, an AC-8 Autocannon. Their LUTs' vanilla texture objects join the test world's.
local LIB_LUT, OPTIC_LUT, MAG_LUT = 'babd338977faa2ff', '69a575a0b0d612d2', '8fdfebf7b69f5a87'
local P2_LUT, AC_LUT = '22cc249402887c11', '7aaa0c0000000001'
local VANILLA = helpers.vanilla
VANILLA[LIB_LUT], VANILLA[OPTIC_LUT], VANILLA[MAG_LUT] = 0x191000000, 0x191001000, 0x191002000
VANILLA[P2_LUT], VANILLA[AC_LUT] = 0x191003000, 0x191004000
local LIB, P2, AC = '968211c0033dce64', '05e4e5c2db6e44a2', 'a8cffb316f0b5c5f'
helpers.weapon_luts[LIB] = {LIB_LUT, OPTIC_LUT, MAG_LUT}
helpers.weapon_luts[P2] = {P2_LUT}
helpers.weapon_luts[AC] = {AC_LUT}
local function liberator(id, unit)
    return {id = id or 0x301, name = LIB, unit = unit or 0x400, units = {(unit or 0x400) + 1, (unit or 0x400) + 2},
            attachments = {[1] = '129e5fb1b13c2018', [2] = '7be1e04a7738e673'}}
end
local function peacemaker() return {id = 0x302, name = P2, unit = 0x410, units = {}, attachments = {}} end
local function autocannon() return {id = 0x303, name = AC, unit = 0x420, units = {}, attachments = {}} end
-- the units of a weapon in the engine, each material bound to its LUT's vanilla texture
local function units_of(w, engine)
    if w.name == LIB then
        engine.unit(w.unit, LIB_LUT) engine.unit(w.units[1], OPTIC_LUT) engine.unit(w.units[2], MAG_LUT)
    elseif w.name == P2 then
        engine.unit(w.unit, P2_LUT)
    else
        engine.unit(w.unit, AC_LUT)
    end
end

-- A world whose local Helldiver carries the Liberator and the Peacemaker (none in hand, as on the ship), Recolor
-- Weapons on unless off; frames run until the weapons are recolored.
local function world(options)
    options = options or {}
    local w = setup({weapons = true, ui = options.ui})
    for slot, weapon in ipairs({liberator(), peacemaker()}) do
        units_of(weapon, w.engine)
        w.weapons.set(slot, weapon)
    end
    w.weapons.hold(options.hold or 0)
    if not options.off then w.instance.set_option('recolor_weapons', true) end
    w.frames(20)
    return w
end
local function vanilla(lut) return VANILLA[lut] end
local function count_weapon_requests(from)
    local n = 0
    for i = from + 1, #requests do if requests[i].weapons then n = n + 1 end end
    return n
end
-- The calls frame a made beyond frame b (negative: fewer).
local function diff(a, b)
    local out = {}
    for k, v in pairs(a) do if v ~= (b[k] or 0) then out[k] = v - (b[k] or 0) end end
    for k, v in pairs(b) do if a[k] == nil then out[k] = -v end end
    return out
end

check('off by default: nothing read for the weapons, their colors kept', function()
    local w, twin = world({off = true}), setup({})
    twin.frames(20)
    assert(w.instance.state.options.recolor_weapons == false, 'default off')
    for _ = 1, 240 do
        local extra = diff(w.frame(), twin.frame())
        assert(next(extra) == nil, 'no call added: ' .. budget.describe(extra))
    end
    assert(w.bound(0x400)[1] == vanilla(LIB_LUT) and w.bound(0x410)[1] == vanilla(P2_LUT), 'their own colors')
end)

check('on, on the ship (no weapon in hand): every weapon unit recolored (attachments too); one 48-byte row read on 1 '
      .. 'frame in 4, nothing else', function()
    local w = world()
    local last
    for i = 1, #requests do if requests[i].target == 'weapons' then last = requests[i] end end
    local twin = world({off = true})
    for _, unit in ipairs({0x400, 0x401, 0x402, 0x410}) do
        for _, object in ipairs(w.bound(unit)) do
            assert(object ~= VANILLA[LIB_LUT] and object ~= VANILLA[OPTIC_LUT] and object ~= VANILLA[MAG_LUT]
                   and object ~= VANILLA[P2_LUT], string.format('unit %x recolored', unit))
        end
    end
    assert(last.target == 'weapons' and #last.weapons == 2 and last.weapons[1].name == LIB
           and last.weapons[1].attachments[1] == '129e5fb1b13c2018', 'both weapons and their attachments planned')
    assert(w.instance.loadout.entry == nil, 'no binding watched without a weapon in hand')
    local rows, checks = 0, 0
    for _ = 1, 240 do
        local due = w.instance.state.next_check
        local extra = diff(w.frame(), twin.frame())
        local frame = w.instance.state.frame
        -- the row on 1 frame in 4; the weapons' binding check (2 reads, one texture in turn) with the 30-frame check
        local reads = (frame % 4 == 2 and 1 or 0) + (frame >= due and 2 or 0)
        rows, checks = rows + (frame % 4 == 2 and 1 or 0), checks + (frame >= due and 1 or 0)
        assert(same(extra, reads > 0 and {read_into = reads} or {}), 'frame ' .. frame .. ': ' .. budget.describe(extra))
    end
    assert(rows == 60 and checks == 8, rows .. ' row reads, ' .. checks .. ' binding checks')
end)

check('a muzzle that binds the weapon\'s own LUT takes the attachment plan, the weapon its own (AR-61 Tenderizer: '
      .. 'HELLDIVER\'s blue light row on its trigger guard)', function()
    local TEN, TEN_LUT = 'ce063aa33d95a812', 'ccca1d110a2ef14f'
    VANILLA[TEN_LUT] = 0x191005000
    helpers.weapon_luts[TEN] = {TEN_LUT, TEN_LUT .. Recolor.ATTACHMENT}
    local w = setup({weapons = true})
    w.engine.unit(0x430, TEN_LUT) w.engine.unit(0x431, TEN_LUT)
    w.weapons.set(1, {id = 0x304, name = TEN, unit = 0x430, units = {0x431}, attachments = {[3] = 'b3e83ecd78fdca9d'}})
    w.weapons.hold(0)
    w.instance.set_option('recolor_weapons', true)
    w.frames(20)
    local textures = w.instance.loadout.controller.textures
    local own, muzzle = textures[TEN_LUT], textures[TEN_LUT .. Recolor.ATTACHMENT]
    assert(own and muzzle and own.object ~= muzzle.object, 'two textures for the one vanilla LUT')
    for _, object in ipairs(w.bound(0x430)) do assert(object == own.object, 'the weapon: its own plan') end
    for _, object in ipairs(w.bound(0x431)) do assert(object == muzzle.object, 'the muzzle: the attachment plan') end
end)

check('NIGHT\'s decal sheet is bound as it is in the decal slot of the weapon\'s materials (the game\'s texture: no '
      .. 'copy, never given to the pool), and put back when the option goes off (control check 2026-10-15)', function()
    local OWN_SHEET, NIGHT_SHEET = '7b3e68f1837b5730', 'f37a4e756300ab32'
    VANILLA[OWN_SHEET], VANILLA[NIGHT_SHEET] = 0x191006000, 0x191007000
    helpers.weapon_decals[LIB] = {{from = OWN_SHEET, to = NIGHT_SHEET}}
    local w = setup({weapons = true})
    w.engine.unit(0x400, LIB_LUT, nil, nil, nil, OWN_SHEET)
    w.engine.unit(0x401, OPTIC_LUT) w.engine.unit(0x402, MAG_LUT)
    w.weapons.set(1, liberator())
    w.weapons.hold(0)
    w.instance.set_option('recolor_weapons', true)
    w.frames(20)
    local function sheets()
        local out = {}
        for _, m in ipairs(w.engine.units[0x400].materials) do
            out[#out + 1] = w.engine.binding(m.material, Fake.DECAL_SLOT)
        end
        return out
    end
    local c = w.instance.loadout.controller
    assert(c.textures[OWN_SHEET] and c.textures[OWN_SHEET].direct, 'the scheme\'s sheet, not a pooled copy')
    for _, object in ipairs(sheets()) do assert(object == VANILLA[NIGHT_SHEET], 'the scheme\'s sheet bound') end
    local given = w.instance.pool.refilled
    w.instance.set_option('recolor_weapons', false)
    w.frames(20)
    for _, object in ipairs(sheets()) do assert(object == VANILLA[OWN_SHEET], 'its own sheet back') end
    assert(w.instance.pool.refilled == given, 'nothing of it given to the pool')
    helpers.weapon_decals[LIB] = nil
end)

check('a weapon in hand: its LUT binding read every frame (8 bytes) and the row on 1 frame in 4; no allocation of '
      .. 'its own', function()
    local w, twin = world({hold = 1}), world({off = true, hold = 1})
    assert(w.instance.loadout.entry, 'the weapon in hand\'s binding watched')
    for _ = 1, 240 do
        local due = w.instance.state.next_check
        local extra = diff(w.frame(), twin.frame())
        local frame = w.instance.state.frame
        local expected = {read_into = 1 + (frame % 4 == 2 and 1 or 0) + (frame >= due and 2 or 0)}
        assert(same(extra, expected), 'frame ' .. frame .. ': ' .. budget.describe(extra) .. ', expected '
               .. budget.describe(expected))
    end
end)

check('a reload binds the weapon\'s own paint again: bound again on the next frame, no job (the magazine\'s new unit '
      .. 'too)', function()
    local w = world({hold = 1})
    local before, recolored = #requests, w.bound(0x400)[1]
    local material = w.engine.units[0x400].materials[1].material
    w.space.u64(w.engine.entry(material) + 8, vanilla(LIB_LUT)) -- the game's reload: the paint's LUT bound again
    w.engine.unit(0x403, MAG_LUT) -- the reloaded magazine: a new unit
    w.space.u32(0x1A4000000 + 12, 0x403) -- its customization record's first magazine (tests/fake_game.lua layout)
    w.frame()
    assert(w.bound(0x400)[1] == recolored, 'bound again the next frame')
    assert(w.bound(0x403)[1] ~= vanilla(MAG_LUT), 'the new magazine too')
    assert(w.instance.loadout.reloads == 1 and count_weapon_requests(before) == 0, 'no job')
end)

check('a support weapon picked up: a job for the new set; a respawn with the same weapons: bound without a job',
      function()
    local w = world({hold = 1})
    local before = #requests
    local ac = autocannon()
    units_of(ac, w.engine)
    w.weapons.set(3, ac)
    w.frames(16)
    assert(count_weapon_requests(before) == 1 and w.bound(0x420)[1] ~= vanilla(AC_LUT), 'planned and bound')
    before = #requests
    local respawned = liberator(0x311, 0x430) -- the same weapon, a new entity and new units
    units_of(respawned, w.engine)
    w.weapons.set(1, respawned)
    w.frames(8)
    assert(count_weapon_requests(before) == 0, 'no job for the same weapons')
    assert(w.bound(0x430)[1] ~= vanilla(LIB_LUT) and w.bound(0x431)[1] ~= vanilla(OPTIC_LUT), 'the new units bound')
end)

check('a grenade thrown (the throwable field) changes nothing: no resolve, no rebind', function()
    local w = world({hold = 1})
    local rebinds = w.instance.loadout.rebinds
    w.space.u32(w.weapons.row() + 16, 0x777) -- the held throwable
    w.frames(8)
    assert(w.instance.loadout.rebinds == rebinds, 'nothing bound again')
end)

check('options: another mode plans the weapons again; Recolor Weapons off gives their colors back and stops every '
      .. 'weapon read', function()
    local w = world({hold = 1})
    local before = #requests
    w.instance.set_option('mode', 3)
    w.frames(30)
    local found
    for i = before + 1, #requests do if requests[i].weapons then found = requests[i] end end
    assert(found and found.mode == 3, 'planned again for Armor Matches Helmet')
    local row, entry = w.weapons.row(), w.instance.loadout.entry
    assert(entry, 'the weapon in hand watched')
    w.instance.set_option('recolor_weapons', false)
    w.frames(6)
    assert(w.bound(0x400)[1] == vanilla(LIB_LUT) and w.bound(0x410)[1] == vanilla(P2_LUT), 'their own colors back')
    -- every read of the inventory row or the watched binding counted from here
    local ffi = require('ffi')
    local read_into, weapon_reads = w.memory.read_into, 0
    w.memory.read_into = function(pointer, size, out)
        local at = type(pointer) == 'number' and pointer or tonumber(ffi.cast('uintptr_t', pointer))
        if at == row or at == entry then weapon_reads = weapon_reads + 1 end
        return read_into(pointer, size, out)
    end
    w.frames(120)
    assert(weapon_reads == 0 and w.instance.loadout.watch == nil, 'no weapon read: ' .. weapon_reads)
end)

check('Off (no color matching, no scheme) recolors no weapon; a paint scheme does', function()
    local w = world()
    w.instance.set_option('mode', 1)
    w.frames(10)
    assert(w.bound(0x400)[1] == vanilla(LIB_LUT), 'Off: own colors')
    w.instance.set_option('scheme', 3)
    w.frames(30)
    assert(w.bound(0x400)[1] ~= vanilla(LIB_LUT), 'a scheme: recolored')
end)

check('Recolor Weapons turned on while the Armory shows a weapon: the preview is recolored without waiting for its '
      .. 'next change (live probe 2026-10-15: it kept its colors until another weapon was shown)', function()
    local w = world({ui = true, off = true})
    w.engine.unit(0x500, LIB_LUT) w.engine.unit(0x501, OPTIC_LUT)
    w.weapons.preview({id = 0, name = LIB, unit = 0x500, units = {0x501}, ids = {'309f7e645a8d2b56'}})
    w.frames(16)
    assert(w.bound(0x500)[1] == vanilla(LIB_LUT), 'off: its own colors')
    w.instance.set_option('recolor_weapons', true)
    w.frames(24)
    assert(w.bound(0x500)[1] ~= vanilla(LIB_LUT) and w.bound(0x501)[1] ~= vanilla(OPTIC_LUT), 'on: recolored')
end)

check('the Armory\'s weapon preview: a job for the weapon it shows; the same weapon again bound at once; closed: its '
      .. 'textures given back; another option plans it again', function()
    local w = world({ui = true})
    -- 0x504: an underbarrel that is a weapon of its own, in the paired slot (the AR-11 Arbitrator's module)
    local shown = {id = 0, name = LIB, unit = 0x500, units = {0x501}, ids = {'309f7e645a8d2b56'}, paired = 0x504}
    w.engine.unit(0x500, LIB_LUT) w.engine.unit(0x501, OPTIC_LUT) w.engine.unit(0x504, MAG_LUT)
    local before = #requests
    w.weapons.preview(shown)
    w.frames(16)
    local found
    for i = before + 1, #requests do if requests[i].target == 'ui_weapon' then found = requests[i] end end
    assert(found and found.weapons[1].name == LIB and found.weapons[1].ids[1] == '309f7e645a8d2b56', 'its request')
    assert(w.bound(0x500)[1] ~= vanilla(LIB_LUT) and w.bound(0x501)[1] ~= vanilla(OPTIC_LUT), 'the preview recolored')
    assert(w.bound(0x504)[1] ~= vanilla(MAG_LUT), 'the underbarrel weapon in the paired slot recolored too')
    before = #requests
    shown.unit, shown.units = 0x502, {0x503} -- the same weapon spawned again (a turntable reset, a re-open)
    w.engine.unit(0x502, LIB_LUT) w.engine.unit(0x503, OPTIC_LUT)
    w.weapons.preview(shown)
    w.frames(8)
    assert(w.bound(0x502)[1] ~= vanilla(LIB_LUT), 'bound at once')
    for i = before + 1, #requests do assert(requests[i].target ~= 'ui_weapon', 'no job for the same weapon') end
    w.instance.set_option('mode', 3)
    w.frames(40)
    found = nil
    for i = before + 1, #requests do if requests[i].target == 'ui_weapon' then found = requests[i] end end
    assert(found and found.mode == 3, 'planned again with the option (live 2026-10-15: it kept its first plan)')
    local pool_free = w.instance.pool.made
    w.weapons.preview(nil)
    w.engine.units[0x502].alive, w.engine.units[0x503].alive = false, false
    w.frames(12)
    assert(#w.instance.loadout.shown_controller.bindings == 0, 'closed: nothing bound')
    assert(w.instance.pool.made == pool_free, 'no texture made')
end)

check('a weapon\'s paint scheme (its MaterialOverride): the request carries the LUT the game binds', function()
    local w = setup({weapons = true})
    local lib = liberator()
    lib.paint = {[0x7c4a4a11] = '72ba1e791ed0a166'} -- m_weapon: Forest Camo
    units_of(lib, w.engine)
    w.weapons.set(1, lib)
    w.instance.set_option('recolor_weapons', true)
    w.frames(20)
    local last
    for i = 1, #requests do if requests[i].target == 'weapons' then last = requests[i] end end
    local o = last.weapons[1].overrides[0]
    assert(o and o.rows[0x7c4a4a11].lut == '72ba1e791ed0a166', 'the scheme\'s LUT for its slot')
    assert(last.sig:find('72ba1e791ed0a166', 1, true), 'in the plan\'s signature')
end)

check('a squadmate sharing Recolor Weapons (cbmyc2 flag 16): their weapons recolored with their settings, their '
      .. 'reload bound again on their watch turn; sharing it no more gives their colors back', function()
    local w = setup({weapons = true, lobby = {local_id = 'C0FFEE5EED0001',
                     members = {{id = 'C0FFEE5EED0001'}, {id = '1234', value = 'v=1;m=3;f=19;s=0;'}}}})
    local theirs = liberator(0x321, 0x600)
    units_of(theirs, w.engine)
    w.weapons.set(1, theirs, 1)
    w.weapons.hold(1, 1)
    w.frames(60)
    assert(w.bound(0x600)[1] ~= vanilla(LIB_LUT) and w.bound(0x601)[1] ~= vanilla(OPTIC_LUT), 'their weapon recolored')
    local found
    for i = 1, #requests do
        if requests[i].target == 'remote' and requests[i].weapons then found = requests[i] end
    end
    assert(found and found.mode == 3 and found.weapons[1].name == LIB, 'with their settings (Armor Matches Helmet)')
    local e = w.instance.remote.entries['0000000000001234']
    assert(e.loadout and e.loadout.entry, 'their weapon in hand watched')
    local recolored = w.bound(0x600)[1]
    w.space.u64(w.engine.entry(w.engine.units[0x600].materials[1].material) + 8, vanilla(LIB_LUT)) -- their reload
    w.frames(8) -- their watch turn comes within WATCH_FRAMES frames
    assert(w.bound(0x600)[1] == recolored and e.loadout.reloads == 1, 'bound again on their turn')
    assert(w.instance.state.options.recolor_weapons == false, 'the local player\'s own option stays off')
    w.lobby.members[2].value = 'v=1;m=3;f=3;s=0;' -- no longer Recolor Weapons
    w.frames(140)
    assert(w.bound(0x600)[1] == vanilla(LIB_LUT) and not e.loadout, 'their colors back')
end)

print('PASS test_weapons (' .. passed .. ' checks)')
