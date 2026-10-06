-- Laser Sentry Cooldown tests: a simulated game. A sparse address space with Windows page attributes, the heat
-- table built from the live bytes of Steam build 25480438 (tests/heat_fixture.lua), the adapter's interface over
-- it with injectable failures, and a session that installs the addon with a fresh update guard.
-- Usage: local G = dofile(root .. '/tests/fake_game.lua')(root)
return function(root)
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
    G.CHANGE = G.RECORD_ADDRESS + Cooldown.CHANGE_OFFSET

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
    -- logged in order.
    function G.fake_api(memory, failures)
        failures = failures or {}
        local api, calls = {}, {}
        function api.u64(address)
            local bytes = memory.peek(address, 8)
            if not bytes then return nil end
            return G.u32(bytes, 0) + G.u32(bytes, 4) * 4294967296
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
            local region = memory.region(address)
            if not region or region.protection ~= G.PAGE_READWRITE or failures.write then return false end
            memory.poke(address, failures.garble and bytes:reverse() or bytes)
            return true
        end
        return api, calls
    end

    G.quiet = function() end

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
        function self.record_change() return memory.peek(G.CHANGE, #Cooldown.VANILLA) end
        function self.logged(pattern)
            for _, line in ipairs(lines) do if line:find(pattern, 1, true) then return true end end
            return false
        end
        return self
    end

    return G
end
