return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    ffi.cdef [[
        void *GetModuleHandleA(const char *name);
        uint32_t GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity);
        void *GetCurrentProcess(void);
        uint64_t GetTickCount64(void);
        void *GetCurrentThread(void);
        int QueryThreadCycleTime(void *thread, void *cycles);
        int QueryPerformanceCounter(void *counter);
        int QueryPerformanceFrequency(void *frequency);
        int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
        typedef struct {
            void *base; void *allocation_base; uint32_t allocation_protection;
            uint16_t partition; uint16_t reserved; size_t size;
            uint32_t state; uint32_t protection; uint32_t type;
        } CorpseRepairMemoryRegion;
        size_t VirtualQuery(const void *address, void *region, size_t size);
        void *CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                          uint32_t disposition, uint32_t flags, void *template_file);
        int ReadFile(void *file, void *buffer, uint32_t size, uint32_t *read, void *overlapped);
        int CloseHandle(void *handle);
        int32_t BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name,
                                            const uint16_t *provider, uint32_t flags);
        int32_t BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags);
        int32_t BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                 const void *secret, uint32_t secret_size, uint32_t flags);
        int32_t BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags);
        int32_t BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags);
        int32_t BCryptDestroyHash(void *hash);
    ]]
    local kernel, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
    -- LuaJIT retains the first function declaration in the shared VM. Use an
    -- opaque buffer when declaring first so another mod's equivalent struct is
    -- accepted. Cast our own call as well for a typed declaration loaded first.
    local query_region = ffi.cast('size_t (*)(const void *, void *, size_t)', kernel.VirtualQuery)
    local process = kernel.GetCurrentProcess()
    local api = {}
    function api.time() return tonumber(kernel.GetTickCount64()) / 1000 end
    local frequency,counter=ffi.new('int64_t[1]'),ffi.new('int64_t[1]')
    local performance_counter=ffi.cast('int (*)(void *)',kernel.QueryPerformanceCounter)
    local performance_frequency=ffi.cast('int (*)(void *)',kernel.QueryPerformanceFrequency)
    assert(performance_frequency(frequency)~=0 and frequency[0]>0,'Performance clock unavailable')
    local ticks_per_second=tonumber(frequency[0])
    function api.clock() performance_counter(counter);return tonumber(counter[0])/ticks_per_second end
    -- Optional read-only diagnostic counter. Raw cycles must not be converted
    -- to milliseconds: CPU timer frequency/implementation varies by hardware.
    local has_cycles,query_cycles=pcall(function()
        return ffi.cast('int (*)(void *, void *)',kernel.QueryThreadCycleTime)
    end)
    if has_cycles then
        local cycle_buffer=ffi.new('uint64_t[1]')
        function api.thread_cycles()
            if query_cycles(kernel.GetCurrentThread(),cycle_buffer)~=0 then return tonumber(cycle_buffer[0]) end
        end
    end

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- ReadProcessMemory does not call back into Lua. Copy to a Lua string before
    -- reusing this scratch space; no borrowed memory survives a read.
    local buffer,count=ffi.new('uint8_t[32768]'),ffi.new('size_t[1]')
    function api.read(address, size)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        if kernel.ReadProcessMemory(process, address, buffer, size, count) == 0 or count[0] ~= size then
            return nil
        end
        return ffi.string(buffer, size)
    end

    local pointer_word=ffi.new('uintptr_t[1]')
    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        -- Copy before conversion; the returned pointer value owns no reference
        -- to this scratch word or the temporary Lua string.
        ffi.copy(pointer_word, ffi.cast('const uint8_t *',bytes)+offset, 8)
        local value=pointer_word[0]
        if value < 0x10000 or value >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value)
    end

    function api.distance(first, second)
        return tonumber(ffi.cast('intptr_t', first) - ffi.cast('intptr_t', second))
    end

    function api.address(pointer)
        -- All accepted Windows user addresses are below 2^47, so a Lua number
        -- represents each byte address exactly. Formatted pointer strings are
        -- display output and must not determine read-cache identity.
        local value=tonumber(ffi.cast('uintptr_t',pointer))
        assert(value>=0x10000 and value<0x800000000000,'Address outside bounds')
        return value
    end

    function api.writable_data(address, size)
        if size <= 0 then return false end
        local cursor = ffi.cast('uint8_t *', address)
        local remaining = size
        local region = ffi.new('CorpseRepairMemoryRegion[1]')
        while remaining > 0 do
            if query_region(cursor, region, ffi.sizeof(region[0])) ~= ffi.sizeof(region[0]) then return false end
            -- Settings must already be writable private data, never executable or mapped module pages.
            if region[0].state ~= 0x1000 or region[0].type ~= 0x20000 or region[0].protection ~= 4 then return false end
            local available = tonumber(region[0].size) - api.distance(cursor, region[0].base)
            if available <= 0 then return false end
            local count = math.min(available, remaining)
            cursor, remaining = cursor + count, remaining - count
        end
        return true
    end

    function api.module_hash(module)
        local path = ffi.new('uint16_t[32768]')
        local length = kernel.GetModuleFileNameW(module, path, 32768)
        assert(length > 0 and length < 32768, 'Cannot resolve module file')
        local file = kernel.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
        assert(file ~= ffi.cast('void *', -1), 'Cannot read module file')
        local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
        local ok, result = pcall(function()
            local name = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})
            assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0, 'SHA256 unavailable')
            assert(bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0, 'SHA256 creation failed')
            local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
            while true do
                assert(kernel.ReadFile(file, buffer, 1048576, count, nil) ~= 0, 'Module file read failed')
                if count[0] == 0 then break end
                assert(bcrypt.BCryptHashData(hash[0], buffer, count[0], 0) == 0, 'SHA256 update failed')
            end
            local digest, hex = ffi.new('uint8_t[32]'), {}
            assert(bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) == 0, 'SHA256 finish failed')
            for i = 0, 31 do hex[#hex + 1] = string.format('%02X', digest[i]) end
            return table.concat(hex)
        end)
        if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
        if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
        kernel.CloseHandle(file)
        if not ok then error(result) end
        return result
    end
    function api.bind(game,exe)
        local function pointer(address)
            return assert(api.pointer(api.read(address,8)),'Physics binding unavailable')
        end
        local binding=pointer(game+0x3326338)
        assert(api.distance(binding,exe)==0x27cd910,'Unsupported physics API')
        for _,entry in ipairs({{8,0x77f4f0},{0x60,0x799880},{0x68,0x799ba0}}) do
            assert(api.distance(pointer(binding+entry[1]),exe)==entry[2],'Unsupported physics function')
        end
        assert(api.read(exe+0x799880,8)=='\x48\x89\x5c\x24\x08\x48\x89\x6c','Position setter changed')
        assert(api.read(exe+0x799ba0,8)=='\x48\x89\x5c\x24\x08\x48\x89\x6c','Rotation setter changed')
        -- Entire captured routine, including its ownership gate and final
        -- update-byte store. Full comparison rejects a changed/detoured body.
        local stop_hex='48895c2408574883ec60488b4138448bc24969d8b82b00004a8b3cc048035948488bcfe86822d5ff80b8c40600000074558b4f08e807e082004885c07448f64014017442448b480c33d2c6442450000f57c0f30f11442448448bc1488b0d9e17cc02895424408954243888542430488d542478f30f11442428c744242001000000e8ba3dc100c683a42b000000488b5c24704883c4605fc3'
        local stop_bytes=stop_hex:gsub('..',function(pair)return string.char(tonumber(pair,16)) end)
        assert(api.read(game+0x7abd00,#stop_bytes)==stop_bytes,'Ragdoll stop routine changed')
        -- Existing owner-routed completion request. Verify all chained unwind
        -- fragments, including the remote branch and owned queue checks.
        local completion_hex='48895c24184889542410564883ec70488bf1418bd8418bc8e8d399c1ff4885c00f8472010000f64014014889bc24800000000f84f20000008b501081faff7f0000742e488b05febb0a02488b4808e8eddfc1ff84c0741a488b0d42cb0b028bd3488b89a8b30000e8340c82ffe91f010000488b0dc062f6018bd3e8816c56ff84c00f840901000033ff488d461c8bcf9039180f84f8000000ffc14883c04083f92072ed8bcf488d86240800000f1f400039180f84d8000000ffc14883c04081f98000000072ea8bcbe82399c1ff4885c00f84ba000000f64014010f84b0000000448b480c488d94248800000040887c24500f57c0f30f11442448448bc3f30f100507630001488bce897c2440897c2438c644243001f30f11442428c744242001000000e8c8f6ffffeb668b701081feff7f0000750433ffeb23488b0d785ef601488b4140488bb860010000488b4138ff5008488bc88bd6ffd7488bf88bcbe88d95c1ff41b901000000c7442460010000004c8d442460c744246404000000488bd74889442468b9326c6621e850df81ff488bbc2480000000488b9c24900000004883c4705ec3'
        local completion_bytes=completion_hex:gsub('..',function(pair)return string.char(tonumber(pair,16)) end)
        assert(api.read(game+0x13c0350,#completion_bytes)==completion_bytes,'Corpse completion request changed')
        local request_completion=ffi.cast('void (*)(void *,uintptr_t,uint32_t)',game+0x13c0350)
        local stop_sync=ffi.cast('void (*)(void *,uint32_t)',game+0x7abd00)
        local position=ffi.cast('void (*)(uint32_t,const float *)',exe+0x799880)
        local rotation=ffi.cast('void (*)(uint32_t,const float *)',exe+0x799ba0)
        local enabled=ffi.cast('void (*)(const uint32_t *,uint32_t,uint32_t)',exe+0x77f4f0)
        -- These engine wrappers validate the actor handle and enqueue native
        -- physics commands. They never write a body pose or broad-phase record
        -- directly. The queue owns copies of the input vectors.
        local function aligned(values)
            local storage=ffi.new('uint8_t[31]')
            local pointer=ffi.cast('float *',storage+(16-tonumber(ffi.cast('uintptr_t',storage)%16))%16)
            for i=1,#values do pointer[i-1]=values[i] end
            return storage,pointer
        end
        return {
            stop_sync=function(manager,index)stop_sync(manager,index) end,
            request_completion=function(entity)
                -- Resolve each time; never keep a scene/service pointer.
                local service=pointer(game+0x346d500)
                assert(api.read(service,24),'Corpse completion service unavailable')
                request_completion(service,0,entity)
            end,
            pose=function(actor,pos,quat)
                local p_owner,p=aligned(pos);local q_owner,q=aligned(quat)
                rotation(actor,q);position(actor,p)
                assert(p_owner~=nil and q_owner~=nil)
            end,
            disable=function(actor)
                local ids=ffi.new('uint32_t[1]',actor)
                enabled(ids,1,0)
            end,
        }
    end
    return api
end
