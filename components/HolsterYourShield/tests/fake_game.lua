-- Holster Your Shield tests: a simulated game. A sparse address space of zeroed regions, the registries the addon
-- reads (players, entities, avatars, inventory, equipment settings) laid out as build 25480438 lays them out, an
-- api over it with the adapter's interface (view/u64 into reused buffers, no allocation), and the game's three
-- functions as the game behaves: set_item sets the held carryable, set_mode sets the carry mode (0 when nothing is
-- held), send_held is recorded.
-- Usage: local G = dofile(root .. '/tests/fake_game.lua')(root)
return function(root)
    local ffi = require('ffi')
    local bit = require('bit')
    local budget = dofile(root .. '/tests/frame_budget.lua')
    local H = dofile(root .. '/tests/hostile_vm.lua')
    local Holster = dofile(root .. '/src/holster_your_shield.lua')
    local G = {budget = budget, H = H, Holster = Holster, ffi = ffi}
    local L = Holster.LAYOUT
    local HIGH = 4294967296

    G.GAME = 0x7FF600000000
    G.AVATAR, G.AVATAR_NET, G.AVATAR_RECORD_INDEX = 1001, 5, 3
    G.RIFLE, G.PISTOL, G.SUPPORT, G.SHIELD, G.DIRECTIONAL, G.SUPPLY, G.DRIVE = 2001, 2002, 2003, 3001, 3002,
                                                                               3003, 4001
    G.KINDS = { -- equipment type, one-handed
        [G.RIFLE] = {8, false}, [G.PISTOL] = {31, true}, [G.SUPPORT] = {11, false}, [G.SHIELD] = {25, true},
        [G.DIRECTIONAL] = {25, true}, [G.SUPPLY] = {23, false}, [G.DRIVE] = {30, true},
    }
    G.RESOURCES = {
        [G.RIFLE] = {0x27EE1ED8, 0xF6FB6356}, [G.PISTOL] = {0x7B06196E, 0x90154C88},
        [G.SUPPORT] = {0x11111111, 0x22222222}, [G.SHIELD] = {0x967ED15E, 0x0BAE363B},
        [G.DIRECTIONAL] = {0xA4E796F8, 0x4801B40A}, [G.SUPPLY] = {0x33333333, 0x44444444},
        [G.DRIVE] = {0x55555555, 0x66666666},
    }
    G.PRESS_BITS = 0x3C888889 -- 1/60 s held, as float bits

    local function mul32(a, b)
        local high, low = math.floor(a / 65536), a % 65536
        return (high * b % 65536 * 65536 + low * b) % HIGH
    end

    -- Copies between real buffers by numeric address, so a simulated read allocates nothing (pointer arithmetic on
    -- cdata would box a new pointer per read and hide the addon's own garbage, or lack of it).
    if not pcall(ffi.typeof, 'hys1test_copied') then
        ffi.cdef([[
typedef struct hys1test_copied { int unused; } hys1test_copied;
void hys1test_memcpy(void *destination, uint64_t source, size_t size) __asm__("memcpy");
]])
    end
    local C = ffi.C

    -- A sparse address space: zeroed regions; reads outside every region fail.
    function G.space()
        local self = {regions = {}, next = 0x10000000}
        function self.region(address, size)
            local buffer = ffi.new('uint8_t[?]', size)
            self.regions[#self.regions + 1] = {base = address, size = size, buffer = buffer,
                                               real = tonumber(ffi.cast('uintptr_t', buffer))}
            return address
        end
        function self.alloc(size)
            local address = self.next
            self.next = self.next + math.ceil((size + 0x1000) / 0x1000) * 0x1000
            return self.region(address, size)
        end
        function self.find(address, size)
            for i = 1, #self.regions do
                local r = self.regions[i]
                if address >= r.base and address + size <= r.base + r.size then return r end
            end
        end
        function self.copy(destination, address, size)
            local r = self.find(address, size)
            if not r then return false end
            C.hys1test_memcpy(destination, r.real + (address - r.base), size)
            return true
        end
        function self.set32(address, value)
            local r = assert(self.find(address, 4), string.format('no region at 0x%x', address))
            ffi.cast('uint32_t *', r.buffer + (address - r.base))[0] = value -- lint-ok: R3 the simulation's own buffer
        end
        function self.get32(address)
            local r = assert(self.find(address, 4))
            return ffi.cast('uint32_t *', r.buffer + (address - r.base))[0]
        end
        function self.set64(address, value)
            self.set32(address, value % HIGH)
            self.set32(address + 4, math.floor(value / HIGH))
        end
        return self
    end

    -- The game's map: a 20-byte header {data, capacity, empty, multiplier} at header over 8-byte buckets.
    function G.map(space, header, entries, capacity, multiplier)
        capacity, multiplier = capacity or 16, multiplier or 2
        local empty = 0
        local data = space.alloc(8 * capacity)
        for key, value in pairs(entries) do
            local product = mul32(key, multiplier)
            for probe = 0, capacity - 1 do
                local slot = data + 8 * bit.band(product + probe, capacity - 1)
                if space.get32(slot) == empty then
                    space.set32(slot, key)
                    space.set32(slot + 4, value)
                    break
                end
            end
        end
        if not space.find(header, 20) then space.region(header, 20) end
        space.set64(header, data)
        space.set32(header + 8, capacity)
        space.set32(header + 12, empty)
        space.set32(header + 16, multiplier)
    end

    -- The world of one local Helldiver with a rifle, a pistol, a support weapon and a ballistic shield.
    -- options.copies: entity ids with a per-entity EquipmentComponent copy (one-handed flipped, to tell them apart).
    function G.world(options)
        options = options or {}
        local space = G.space()
        local w = {space = space, options = options}
        local function global(rva, value)
            space.region(G.GAME + rva, 8)
            space.set64(G.GAME + rva, value)
        end
        space.region(G.GAME + L.none_item, 4)
        space.region(G.GAME + L.none_slot, 4)
        -- entities
        local owner = space.alloc(16)
        w.owner = owner
        global(L.owner, owner)
        space.region(owner + 0xF32F18, 24 * 32)
        local entity_index = {}
        local next_index = 5
        function w.record(index, low, high, entity, owned)
            local address = owner + 0xF32F18 + 24 * index
            space.set32(address, low)
            space.set32(address + 4, high)
            space.set32(address + 8, entity)
            space.set32(address + 20, owned and 1 or 0)
            return address
        end
        for entity, resource in pairs(G.RESOURCES) do
            entity_index[entity] = next_index
            w.record(next_index, resource[1], resource[2], entity, true)
            next_index = next_index + 1
        end
        w.avatar_record = w.record(G.AVATAR_RECORD_INDEX, 0x294DFA97, 0x4D1C334D, G.AVATAR, true)
        entity_index[G.AVATAR] = G.AVATAR_RECORD_INDEX
        G.map(space, owner + 0xF22EC8, {[G.AVATAR_NET] = G.AVATAR_RECORD_INDEX})
        G.map(space, owner + 0xF1AEB0, entity_index, 32)
        -- shared equipment settings: 688 slots, then records; the shield's home slot is taken by another key
        local table_address = space.alloc(688 * 16 + 232 * 16)
        space.region(owner + 0xF12BC0, 8)
        space.set64(owner + 0xF12BC0, table_address)
        local n = 0
        for entity, kind in pairs(G.KINDS) do
            local low, high = G.RESOURCES[entity][1], G.RESOURCES[entity][2]
            local slot = (high * (HIGH % 688) + low) % 688
            if entity == G.SHIELD then
                space.set32(table_address + 16 * slot, 0xABCDEF)
                slot = (slot + 1) % 688
            end
            while space.get32(table_address + 16 * slot) ~= 0 or space.get32(table_address + 16 * slot + 4) ~= 0 do
                slot = (slot + 1) % 688
            end
            space.set32(table_address + 16 * slot, low)
            space.set32(table_address + 16 * slot + 4, high)
            space.set32(table_address + 16 * slot + 8, n)
            local record = table_address + 688 * 16 + 232 * n
            space.set32(record + 0x80, kind[1])
            space.set32(record + 0xC4, kind[2] and 1 or 0)
            n = n + 1
        end
        -- per-entity copies
        local copies = space.alloc(160)
        global(L.equipment, copies)
        local copy_records = space.alloc(232 * 8)
        space.set64(copies + 144, copy_records)
        local copy_entries = {}
        for i, entity in ipairs(options.copies or {}) do
            copy_entries[entity] = i - 1
            local kind = G.KINDS[entity]
            space.set32(copy_records + 232 * (i - 1) + 0x80, kind[1])
            space.set32(copy_records + 232 * (i - 1) + 0xC4, kind[2] and 0 or 1)
        end
        G.map(space, copies + 80, copy_entries)
        -- players
        local players = space.alloc(0x400)
        global(L.players, players)
        local player = space.alloc(24)
        space.set32(player + 20, 1)
        space.set32(players + 0x84, 1)
        space.set32(players + 0x88, 1)
        space.set64(players + 0xE8, player)
        space.set32(players + 0x3A8, G.AVATAR_NET)
        w.players, w.player = players, player
        -- avatars
        local manager = space.alloc(0x200)
        w.manager = manager
        global(L.avatars, manager)
        G.map(space, manager + 0xF8, {[G.AVATAR] = 0}, 8)
        space.set32(manager + 0x6C, 1)
        space.set64(manager + 0x110, w.avatar_record)
        w.key = manager + 0x150 + 0x1B68 + 37 * 32 + 8
        space.region(manager + 0x150 + 0x1B68, 41 * 32)
        -- inventory
        local inventory = space.alloc(96)
        w.inventory = inventory
        global(L.inventory, inventory)
        G.map(space, inventory + 40, {[G.AVATAR] = 1})
        local identities = space.alloc(8 * 4)
        space.set64(identities + 8, w.avatar_record)
        space.set64(inventory + 64, identities)
        local rows = space.alloc(48 * 4)
        space.set64(inventory + 80, rows)
        w.rows, w.row = rows, rows + 48
        space.set32(w.row, G.RIFLE)
        space.set32(w.row + 4, G.PISTOL)
        space.set32(w.row + 8, G.SUPPORT)

        function w.set_row(row)
            if row.backpack then space.set32(w.row + 12, row.backpack) end
            if row.held then space.set32(w.row + 20, row.held) end
            if row.slot then space.set32(w.row + 28, row.slot) end
            if row.mode then space.set32(w.row + 32, row.mode) end
        end
        function w.row_state()
            return {backpack = space.get32(w.row + 12), held = space.get32(w.row + 20), slot = space.get32(w.row + 28),
                    mode = space.get32(w.row + 32)}
        end
        function w.key_bits(bits) space.set32(w.key, bits) end
        function w.press() w.key_bits(G.PRESS_BITS) end
        function w.release() w.key_bits(0) end
        -- The game draws the shield (0xA95A90 after a one-handed wield) or stows it (0xA95910).
        function w.game_draws() w.set_row({held = space.get32(w.row + 12), mode = 2}) end
        function w.game_stows() w.set_row({held = 0, mode = 1}) end
        -- The game moves the inventory rows (a death in the squad): the avatar's row index changes.
        function w.move_row(index)
            local old = w.row
            local new = rows + 48 * index
            for offset = 0, 44, 4 do space.set32(new + offset, space.get32(old + offset)) end
            for offset = 0, 44, 4 do space.set32(old + offset, 0) end
            space.set64(identities + 8 * index, w.avatar_record)
            G.map(space, inventory + 40, {[G.AVATAR] = index})
            w.row = new
        end
        -- A new avatar entity (a respawn): same record slot, new entity id; the maps follow.
        function w.respawn(entity)
            space.set32(w.avatar_record + 8, entity)
            G.map(space, manager + 0xF8, {[entity] = 0}, 8)
            G.map(space, inventory + 40, {[entity] = 1})
        end
        return w
    end

    -- The adapter over a world: view/u64 into reused buffers and the game's functions acting on the world.
    -- options.inert: the functions do nothing (the game did not take the move).
    function G.api(w, options)
        options = options or {}
        local view = ffi.new('uint8_t[64]')
        local pair = ffi.new('uint32_t[2]')
        local api = {bytes = view, words = ffi.cast('uint32_t *', view), calls = {}}
        local space = w.space
        function api.view(address, size)
            if size < 1 or size > 64 then return false end
            return space.copy(view, address, size)
        end
        function api.u64(address)
            if not space.copy(pair, address, 8) then return nil end
            return pair[0] + pair[1] * HIGH
        end
        local function row_of(inventory, avatar)
            if inventory ~= w.inventory or options.inert then return nil end
            if avatar ~= space.get32(w.avatar_record + 8) then return nil end
            return w.row
        end
        function api.set_item(inventory, avatar, item)
            api.calls[#api.calls + 1] = {'set_item', inventory, avatar, item}
            local row = row_of(inventory, avatar)
            if row then space.set32(row + 20, item) end
        end
        function api.set_mode(inventory, avatar, mode)
            api.calls[#api.calls + 1] = {'set_mode', inventory, avatar, mode}
            local row = row_of(inventory, avatar)
            if row then space.set32(row + 32, space.get32(row + 20) == 0 and 0 or mode) end
        end
        function api.send_held(peer, avatar, item, mode)
            api.calls[#api.calls + 1] = {'send_held', peer, avatar, item, mode}
        end
        return api
    end

    -- An instance on a world, with its log lines and live call counts (frame_budget.wrap).
    function G.session(w, options)
        options = options or {}
        local api = G.api(w, options)
        local lines = {}
        local counts = budget.wrap(api)
        local instance = Holster.new(api, G.GAME, function(line) lines[#lines + 1] = line end)
        instance:read_nones()
        local s = {w = w, api = api, lines = lines, counts = counts, instance = instance}
        function s.frame() return budget.frame(counts, instance.step) end
        function s.frames(n) for _ = 1, n do instance.step() end end
        -- Steps until a check frame has resolved (the first resolution happens on a check frame).
        function s.settle()
            for _ = 1, Holster.CHECK_FRAMES + 1 do instance.step() end
            assert(instance.kept, 'not resolved after a check frame: ' .. table.concat(lines, ' | '))
        end
        function s.last(pattern)
            for i = #lines, 1, -1 do if lines[i]:find(pattern) then return lines[i] end end
        end
        return s
    end

    return G
end
