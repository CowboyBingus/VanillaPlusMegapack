-- Laser Sentry Cooldown tests: a simulated game. A sparse address space with Windows page attributes, the heat
-- table built from the live bytes of Steam build 25480438 (tests/heat_fixture.lua), the adapter's interface over
-- it with injectable failures, and a session that installs the addon with a fresh update guard.
-- Usage: local G = dofile(root .. '/tests/fake_game.lua')(root)
return function(root)
    local ffi = require('ffi')
    local budget = dofile(root .. '/tests/frame_budget.lua')
    local H = dofile(root .. '/tests/hostile_vm.lua')
    local fixture = dofile(root .. '/tests/heat_fixture.lua')
    local Cooldown = dofile(root .. '/src/laser_sentry_cooldown.lua')
    local G = {budget = budget, H = H, fixture = fixture, Cooldown = Cooldown}

    G.MEM_COMMIT, G.MEM_PRIVATE, G.MEM_IMAGE = 0x1000, 0x20000, 0x1000000
    G.PAGE_READONLY, G.PAGE_READWRITE, G.PAGE_EXECUTE_READ = 0x02, 0x04, 0x20
    G.GAME, G.ROOT, G.HEAT = 0x7FF600000000, 0x20000000000, 0x30000000057C -- the live table is not 8-byte aligned
    G.BLOCK_BASE, G.BLOCK_SIZE = 0x300000000000, 0x123B000                -- the live region's size

    local function hex(text) return (text:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)) end
    G.HEADER, G.SLOTS, G.RECORD = hex(fixture.header), hex(fixture.slots), hex(fixture.record)
    G.RECORD_ADDRESS = G.HEAT + Cooldown.RECORDS_OFFSET + Cooldown.RECORD_SIZE * fixture.index
    G.COOLING = G.RECORD_ADDRESS + Cooldown.COOLING_OFFSET
    G.ABILITY = G.RECORD_ADDRESS + Cooldown.ABILITY_OFFSET
    -- The record's two changed ranges joined (cooling rule, then overheat ability), vanilla.
    G.VANILLA = Cooldown.COOLING_VANILLA .. Cooldown.ABILITY_VANILLA

    function G.le32(value)
        return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256,
                           math.floor(value / 16777216) % 256)
    end
    function G.le64(value) return G.le32(value % 4294967296) .. G.le32(math.floor(value / 4294967296)) end
    function G.u32(bytes, offset)
        local a, b, c, d = bytes:byte(offset + 1, offset + 4)
        return a + b * 256 + c * 65536 + d * 16777216
    end

    -- A sparse address space: regions with Windows page attributes, bytes only where something was put.
    function G.space()
        local self = {bytes = {}, regions = {}}
        function self.map(base, size, protection, kind)
            local region = {base = base, size = size, state = G.MEM_COMMIT, protection = protection, type = kind}
            self.regions[#self.regions + 1] = region
            return region
        end
        function self.region(address)
            for _, region in ipairs(self.regions) do
                if address >= region.base and address < region.base + region.size then return region end
            end
        end
        function self.poke(address, bytes)
            for i = 1, #bytes do self.bytes[address + i - 1] = bytes:byte(i) end
        end
        function self.peek(address, size)
            if not self.region(address) or not self.region(address + size - 1) then return nil end
            local out = {}
            for i = 0, size - 1 do
                local byte = self.bytes[address + i]
                if not byte then return nil end
                out[#out + 1] = string.char(byte)
            end
            return table.concat(out)
        end
        return self
    end

    -- The heat table as the game builds it, from the live bytes. options.root / options.table: 0 = not set yet.
    function G.world(options)
        options = options or {}
        local memory = G.space()
        memory.map(G.GAME, 0x4000000, G.PAGE_READWRITE, G.MEM_IMAGE)
        memory.map(G.ROOT, 0x1000000, G.PAGE_READWRITE, G.MEM_PRIVATE)
        memory.block = memory.map(G.BLOCK_BASE, G.BLOCK_SIZE, options.protection or G.PAGE_READONLY,
                                  options.kind or G.MEM_PRIVATE)
        memory.poke(G.GAME + Cooldown.ROOT_RVA, G.le64(options.root or G.ROOT))
        memory.poke(G.ROOT + Cooldown.TABLE_OFFSET, G.le64(options.table or G.HEAT))
        memory.poke(G.HEAT - Cooldown.HEADER_SIZE, options.header or G.HEADER)
        memory.poke(G.HEAT, options.slots or G.SLOTS)
        memory.poke(G.RECORD_ADDRESS, options.record or G.RECORD)
        return memory
    end

    -- The adapter's interface over the simulated space, with injectable failures; page and write calls are
    -- logged in order. failures.second_write: only the second write of the session fails. u64 and view
    -- allocate nothing, as in game, so the allocation checks measure the addon and not this double.
    local VIEW_SIZE = 2048
    function G.fake_api(memory, failures)
        failures = failures or {}
        local view = ffi.new('uint8_t[?]', VIEW_SIZE)
        local api, calls, writes = {bytes = view, words = ffi.cast('uint32_t *', view)}, {}, 0
        local function readable(address, size)
            return memory.region(address) ~= nil and memory.region(address + size - 1) ~= nil
        end
        function api.u64(address)
            if not readable(address, 8) then return nil end
            local bytes, value, scale = memory.bytes, 0, 1
            for i = 0, 7 do
                local byte = bytes[address + i]
                if not byte then return nil end
                value, scale = value + byte * scale, scale * 256
            end
            return value
        end
        function api.view(address, size)
            if size < 1 or size > VIEW_SIZE or not readable(address, size) then return false end
            local bytes = memory.bytes
            for i = 0, size - 1 do
                local byte = bytes[address + i]
                if not byte then return false end
                view[i] = byte
            end
            return true
        end
        function api.read(address, size) return memory.peek(address, size) end
        function api.page(address)
            calls[#calls + 1] = 'page'
            local region = memory.region(address)
            if not region or failures.query then return nil end
            return region.state, region.protection, region.type, region.base, region.size
        end
        function api.protect(address, size, protection)
            calls[#calls + 1] = 'protect ' .. protection
            local region = memory.region(address)
            if not region or failures.protect then return nil end
            if failures.restore and protection ~= G.PAGE_READWRITE then return nil end
            local previous = region.protection
            region.protection = protection
            return previous
        end
        function api.write(address, bytes)
            calls[#calls + 1] = 'write'
            writes = writes + 1
            if failures.second_write and writes == 2 then return false end
            local region = memory.region(address)
            if not region or region.protection ~= G.PAGE_READWRITE or failures.write then return false end
            memory.poke(address, failures.garble and bytes:reverse() or bytes)
            return true
        end
        return api, calls
    end

    -- The WeaponHeat and behavior managers of a mission, for the turret watch: heat instances (entity record,
    -- replicated overheated flag) and the behavior blocks of those that have one. add() takes {id, sentry (the
    -- Laser Sentry resource, else another weapon), flags (entity record +20: 1 = owned and simulated here),
    -- overheated, behavior (id, or false for none), state, request (pending state request, default none)};
    -- sync() writes everything; turret(instance) reads its behavior block back (state, pending request, last
    -- state set); apply_requests() does what the game's behavior manager does before each behavior update
    -- (0x843040): a pending request is applied through set_state unless the behavior refuses it (308: in state
    -- 12). options: capacity (map capacity), kind (the behavior memory's type), wrong_record (the map points the
    -- sentry at another entity's block).
    G.HEAT_MANAGER, G.ENTITIES, G.BEHAVIOR_MANAGER = 0x50000000000, 0x51000000000, 0x52000000000
    G.MAP_EMPTY, G.MAP_MULTIPLIER = 0xFFFFFFFF, 0x9E3779B1
    -- (a * b) mod 2^32, exact: the engine's 32-bit product, computed independently of the addon's shortcut.
    local function mul32(a, b)
        local a_low, a_high, b_low, b_high = a % 65536, math.floor(a / 65536), b % 65536, math.floor(b / 65536)
        return ((a_high * b_low + a_low * b_high) % 65536 * 65536 + a_low * b_low) % 4294967296
    end
    function G.scene(memory, options)
        options = options or {}
        local self = {instances = {}, capacity = options.capacity or 16}
        memory.map(G.HEAT_MANAGER, 0x10000, G.PAGE_READWRITE, G.MEM_PRIVATE)
        memory.map(G.ENTITIES, 0x10000, G.PAGE_READWRITE, G.MEM_PRIVATE)
        memory.map(G.BEHAVIOR_MANAGER, 0x100000, G.PAGE_READWRITE, options.kind or G.MEM_PRIVATE)
        memory.poke(G.GAME + Cooldown.HEAT_MANAGER_RVA, G.le64(G.HEAT_MANAGER))
        memory.poke(G.GAME + Cooldown.BEHAVIOR_MANAGER_RVA, G.le64(G.BEHAVIOR_MANAGER))
        local slots = 0
        function self.add(instance)
            instance.record = G.ENTITIES + 64 * slots
            slots = slots + 1
            if instance.behavior == nil then instance.behavior = Cooldown.BEHAVIOR_ID end
            instance.state = instance.state or 13
            instance.flags = instance.flags or 1
            instance.overheated = instance.overheated or 0
            self.instances[#self.instances + 1] = instance
            return instance
        end
        function self.remove(instance)
            for i, other in ipairs(self.instances) do
                if other == instance then table.remove(self.instances, i); return end
            end
        end
        local function blocks()
            local list = {}
            for _, instance in ipairs(self.instances) do
                if instance.behavior then list[#list + 1] = instance end
            end
            return list
        end
        local function write_map(list)
            local entries = G.BEHAVIOR_MANAGER + 0x1000
            for slot = 0, self.capacity - 1 do memory.poke(entries + 8 * slot, G.le32(G.MAP_EMPTY) .. G.le32(0)) end
            for index, instance in ipairs(list) do
                local target = options.wrong_record and (index % #list) or (index - 1)
                for k = 0, self.capacity - 1 do
                    local slot = (k + mul32(instance.id, G.MAP_MULTIPLIER)) % 4294967296 % self.capacity
                    if G.u32(memory.peek(entries + 8 * slot, 4), 0) == G.MAP_EMPTY then
                        memory.poke(entries + 8 * slot, G.le32(instance.id) .. G.le32(target))
                        break
                    end
                end
            end
        end
        function self.sync()
            local heat, count = G.HEAT_MANAGER, #self.instances
            memory.poke(heat, string.rep('\0', 20) .. G.le32(count) .. G.le32(count) .. G.le32(count)
                .. string.rep('\0', 32) .. G.le64(heat + 0x1000) .. string.rep('\0', 16) .. G.le64(heat + 0x2000))
            for i, instance in ipairs(self.instances) do
                memory.poke(heat + 0x1000 + 8 * (i - 1), G.le64(instance.record))
                memory.poke(heat + 0x2000 + 12 * (i - 1), G.le32(0) .. G.le32(0) .. string.char(instance.overheated, 0)
                    .. '\0\0')
                local low, high = Cooldown.RESOURCE_LOW, Cooldown.RESOURCE_HIGH
                if not instance.sentry then low, high = 0x11111111, 0x22222222 end
                memory.poke(instance.record, G.le32(low) .. G.le32(high) .. G.le32(instance.id) .. G.le32(0)
                    .. G.le32(0) .. G.le32(instance.flags))
            end
            local manager, list = G.BEHAVIOR_MANAGER, blocks()
            memory.poke(manager + 48, G.le32(0) .. G.le32(#list) .. G.le32(0) .. G.le32(0) .. G.le64(manager + 0x1000)
                .. G.le32(self.capacity) .. G.le32(G.MAP_EMPTY) .. G.le32(G.MAP_MULTIPLIER) .. G.le32(0)
                .. G.le64(manager + 0x2000) .. G.le64(manager + 0x3000))
            write_map(list)
            for index, instance in ipairs(list) do
                memory.poke(manager + 0x2000 + 8 * (index - 1), G.le64(instance.record))
                instance.block = manager + 0x3000 + Cooldown.BEHAVIOR_SIZE * (index - 1)
                memory.poke(instance.block, G.le32(instance.behavior) .. G.le32(0) .. G.le32(instance.state)
                    .. G.le32(instance.request or 0xFFFFFFFF) .. G.le32(instance.state))
            end
        end
        -- The instance's behavior block as it is now: state, pending request, last state set.
        function self.turret(instance)
            local bytes = memory.peek(instance.block + 8, 12)
            return G.u32(bytes, 0), G.u32(bytes, 4), G.u32(bytes, 8)
        end
        -- The game's next behavior update: each pending request becomes the state (0x32B6B0 stores the state,
        -- -1 as the request and the state as the last set), unless state 12 refuses it (0x4962C0 for 308).
        function self.apply_requests()
            for _, instance in ipairs(self.instances) do
                if instance.block then
                    local state, request = self.turret(instance)
                    if request ~= 0xFFFFFFFF and state ~= 12 then
                        memory.poke(instance.block + 8, G.le32(request) .. G.le32(0xFFFFFFFF) .. G.le32(request))
                        instance.state, instance.request = request, nil
                    end
                end
            end
        end
        return self
    end

    G.quiet = function() end

    -- The simulated memory is interpreted, like the addon's own look: its byte loops stand in for one
    -- ReadProcessMemory, so traces of them must not show up in the addon's allocation checks.
    if type(jit) == 'table' then
        for _, fn in ipairs({G.space, G.fake_api, G.scene, G.le32, G.le64, G.u32}) do jit.off(fn, true) end
    end

    -- One session: a fresh runtime, a fake loader and log, an env holding the game's update and shutdown, and
    -- the addon installed on the simulated world. options: world fields, failures, below (a frame on which the
    -- update below raises), loader (false: none), bad_build, no_modules, clock (a function returning seconds).
    function G.session(options)
        options = options or {}
        local runtime = dofile(root .. '/src/bingus_runtime.lua')
        local lines = {}
        local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
        local loader = options.loader
        if loader == nil then loader = {api = 1, jit = {}, open_log = function() return log end} end
        rawset(_G, 'CowboyBingusModLoader', loader or nil)
        local env = {frames = 0}
        env.update = function(dt) env.frames = env.frames + 1; return 'below', dt end
        env.shutdown = function() env.shut = true; return 'closed' end
        if options.below then H.chain(env, 'throw_below', {raise_on = options.below}) end
        local memory = options.world or G.world(options)
        local api, calls = G.fake_api(memory, options.failures)
        local counts = budget.wrap(api)
        local fake_memory = {
            module = function(name) if options.no_modules then return nil end; return name or 'exe' end,
            address = function() return G.GAME end,
            time = options.clock or function() return env.frames / 60 end,
            verify_build = function(build)
                assert(build.game_sha256 == Cooldown.GAME_SHA256 and build.exe_sha256 == Cooldown.EXE_SHA256)
                if options.bad_build then return false, 'unsupported game build' end
                return true
            end,
        }
        local saved_print = print
        print = G.quiet
        local install_counts, instance = budget.frame(counts, Cooldown.install, runtime, fake_memory,
                                                      {adapter = function() return api end, env = env})
        print = saved_print
        local self = {runtime = runtime, env = env, memory = memory, api = api, calls = calls, counts = counts,
                      lines = lines, instance = instance, install_counts = install_counts, fake_memory = fake_memory}
        function self.frame()
            local saved = print
            print = G.quiet
            local result = {budget.frame(counts, env.update, 1 / 60)}
            print = saved
            return result[1], result[2], result[3]
        end
        -- The record's two changed ranges joined: compare with G.VANILLA or the tests' PATCHED.
        function self.record_change()
            local cooling = memory.peek(G.COOLING, #Cooldown.COOLING_VANILLA)
            local ability = memory.peek(G.ABILITY, #Cooldown.ABILITY_VANILLA)
            return cooling and ability and cooling .. ability
        end
        function self.logged(pattern)
            for _, line in ipairs(lines) do if line:find(pattern, 1, true) then return true end end
            return false
        end
        return self
    end

    return G
end
