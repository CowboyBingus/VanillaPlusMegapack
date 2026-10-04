return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Every Windows function has a private name (an __asm__ label naming the
    -- real export): LuaJIT keeps the first prototype declared for a name in the
    -- whole shared state, so another mod's declaration of the real names can no
    -- longer change the prototype this mod calls with.
    ffi.cdef [[
        void *hd2ecs_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *hd2ecs_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        uint64_t hd2ecs_GetTickCount64(void) __asm__("GetTickCount64");
        void *hd2ecs_GetCurrentThread(void) __asm__("GetCurrentThread");
        int hd2ecs_QueryThreadCycleTime(void *thread, void *cycles) __asm__("QueryThreadCycleTime");
        int hd2ecs_QueryPerformanceCounter(void *counter) __asm__("QueryPerformanceCounter");
        int hd2ecs_QueryPerformanceFrequency(void *frequency) __asm__("QueryPerformanceFrequency");
        int hd2ecs_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                     size_t *read) __asm__("ReadProcessMemory");
        int hd2ecs_ReadProcessMemoryAt(void *process, uintptr_t address, void *buffer, size_t size,
                                       size_t *read) __asm__("ReadProcessMemory");
    ]]
    -- Declared once per process: parsing it again would add new C types each time.
    if not pcall(ffi.typeof,'hd2ecs_address_cell') then
        ffi.cdef('typedef union { const void *pointer; struct { uint32_t low, high; }; } hd2ecs_address_cell;')
    end
    local kernel = ffi.load('kernel32')
    local process = kernel.hd2ecs_GetCurrentProcess()
    local api = {}
    function api.time() return tonumber(kernel.hd2ecs_GetTickCount64()) / 1000 end
    local frequency=ffi.new('int64_t[1]')
    local performance_counter=kernel.hd2ecs_QueryPerformanceCounter
    local performance_frequency=kernel.hd2ecs_QueryPerformanceFrequency
    assert(performance_frequency(frequency)~=0 and frequency[0]>0,'Performance clock unavailable')
    local ticks_per_second=tonumber(frequency[0])
    -- Read the counter as two 32-bit halves: indexing a 64-bit integer boxes a
    -- new cdata on every call, and the clock runs on every budget check.
    local halves=ffi.new('uint32_t[2]')
    function api.clock() performance_counter(halves);return (halves[0]+halves[1]*4294967296)/ticks_per_second end
    -- Optional read-only diagnostic counter. Raw cycles must not be converted
    -- to milliseconds: CPU timer frequency/implementation varies by hardware.
    local has_cycles,query_cycles=pcall(function()
        return kernel.hd2ecs_QueryThreadCycleTime
    end)
    if has_cycles then
        -- Two 32-bit halves avoid boxing a 64-bit cdata per call. The pseudo
        -- handle always names the calling thread, so it is fetched once.
        local cycle_halves,thread=ffi.new('uint32_t[2]'),kernel.hd2ecs_GetCurrentThread()
        function api.thread_cycles()
            if query_cycles(thread,cycle_halves)~=0 then return cycle_halves[0]+cycle_halves[1]*4294967296 end
        end
    end

    function api.module(name)
        local handle = kernel.hd2ecs_GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- ReadProcessMemory does not call back into Lua. Copy to a Lua string before
    -- reusing this scratch space; no borrowed memory survives a read.
    local buffer,count=ffi.new('uint8_t[32768]'),ffi.new('size_t[1]')
    -- The copied byte count is compared as two 32-bit halves: reading the 64-bit
    -- count itself makes a new cdata object on every interpreted call.
    local count_halves=ffi.cast('uint32_t *',count)
    -- A number address (an integer below 2^47) is passed as an integer, so the
    -- caller makes no pointer object for it.
    local read_at=kernel.hd2ecs_ReadProcessMemoryAt
    function api.read(address, size)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        if type(address)=='number' then
            if address<0x10000 or address>=0x800000000000 or address%1~=0
                or read_at(process, address, buffer, size, count) == 0
                or count_halves[0] ~= size or count_halves[1] ~= 0 then return nil end
            return ffi.string(buffer, size)
        end
        if kernel.hd2ecs_ReadProcessMemory(process, address, buffer, size, count) == 0
            or count_halves[0] ~= size or count_halves[1] ~= 0 then
            return nil
        end
        return ffi.string(buffer, size)
    end

    -- Validation view: the same copy into a separate scratch buffer, returned
    -- as a pointer instead of a new Lua string. Valid until the next view;
    -- compared in place, or copied out at once (a capture of several guarded
    -- words), never stored.
    local view_buffer=ffi.new('uint8_t[32768]')
    -- A number address is taken as api.read takes it: no pointer object.
    function api.view(address, size)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        if type(address)=='number' then
            if address<0x10000 or address>=0x800000000000 or address%1~=0
                or read_at(process, address, view_buffer, size, count) == 0
                or count_halves[0] ~= size or count_halves[1] ~= 0 then return nil end
            return view_buffer
        end
        if kernel.hd2ecs_ReadProcessMemory(process, address, view_buffer, size, count) == 0
            or count_halves[0] ~= size or count_halves[1] ~= 0 then
            return nil
        end
        return view_buffer
    end
    -- The view copies the same memory api.read does. Anything that replaces
    -- api.read (a replay, a counting wrapper) breaks this pairing, and callers
    -- then fall back to string reads through the replacement.
    api.view_read=api.read

    -- One pointer object per decoded value. A pointer cdata is immutable, so the
    -- same object for the same value cannot be told apart from a fresh cast, and
    -- an interpreted call then allocates nothing. Weak values: objects nobody
    -- holds any more are collected as usual.
    local pointers,byte=setmetatable({},{__mode='v'}),string.byte
    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        -- Little-endian decode straight from the string: exact below 2^53, and
        -- every value from 2^47 up is rejected, as before.
        local b1,b2,b3,b4,b5,b6,b7,b8=byte(bytes,offset+1,offset+8)
        local value=b1+b2*256+b3*65536+b4*16777216+(b5+b6*256+b7*65536+b8*16777216)*4294967296
        if value < 0x10000 or value >= 0x800000000000 then return nil end
        local pointer=pointers[value]
        if not pointer then pointer=ffi.cast('uint8_t *', value);pointers[value]=pointer end
        return pointer
    end

    -- A 'uint8_t *' becomes a number through this cell, read back as two 32-bit
    -- halves: converting it to a 64-bit integer makes a new cdata object on
    -- every interpreted call. One union, not two views of the same memory, so
    -- compiled code sees the store. Other values take the plain conversion.
    local cell,byte_pointer=ffi.new('hd2ecs_address_cell'),ffi.typeof('uint8_t *')
    local function slot_number(pointer) cell.pointer=pointer;return cell.low+cell.high*4294967296 end
    function api.distance(first, second)
        if ffi.istype(byte_pointer,first) and ffi.istype(byte_pointer,second) then
            -- Exact below 2^53, like the 64-bit difference.
            local a,b=slot_number(first),slot_number(second)
            if a<9007199254740992 and b<9007199254740992 then return a-b end
        end
        return tonumber(ffi.cast('intptr_t', first) - ffi.cast('intptr_t', second))
    end

    function api.address(pointer)
        -- All accepted Windows user addresses are below 2^47, so a Lua number
        -- represents each byte address exactly. Formatted pointer strings are
        -- display output and must not determine read-cache identity.
        local value=ffi.istype(byte_pointer,pointer) and slot_number(pointer) or tonumber(ffi.cast('uintptr_t',pointer))
        assert(value>=0x10000 and value<0x800000000000,'Address outside bounds')
        return value
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
