return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    ffi.cdef [[
        void *GetModuleHandleA(const char *name);
        uint32_t GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity);
        void *GetCurrentProcess(void);
        uint64_t GetTickCount64(void);
        int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
        int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
        typedef struct {
            void *base; void *allocation_base; uint32_t allocation_protection;
            uint16_t partition; uint16_t reserved; size_t size;
            uint32_t state; uint32_t protection; uint32_t type;
        } SentryAimMemoryRegion;
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

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- One scratch buffer, grown on demand, instead of two allocations per read.
    -- ReadProcessMemory does not call back into Lua, and the bytes are copied
    -- into a Lua string before the buffer is reused.
    local scratch_size, scratch, count = 4096, ffi.new('uint8_t[4096]'), ffi.new('size_t[1]')
    function api.read(address, size)
        if size < 0 or size > scratch_size then scratch, scratch_size = ffi.new('uint8_t[?]', size), size end
        if kernel.ReadProcessMemory(process, address, scratch, size, count) == 0 or count[0] ~= size then
            return nil
        end
        return ffi.string(scratch, size)
    end

    function api.write(address, bytes)
        if not api.writable_data(address, #bytes) then return false end
        local count = ffi.new('size_t[1]')
        return kernel.WriteProcessMemory(process, address, bytes, #bytes, count) ~= 0 and count[0] == #bytes
    end

    local pointer_word = ffi.new('uintptr_t[1]')
    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        -- Reused word, copied straight from the string: no allocation per pointer.
        local value = pointer_word
        ffi.copy(value, ffi.cast('const uint8_t *', bytes) + offset, 8)
        if value[0] < 0x10000 or value[0] >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value[0])
    end

    function api.distance(first, second)
        return tonumber(ffi.cast('intptr_t', first) - ffi.cast('intptr_t', second))
    end

    function api.writable_data(address, size)
        if size <= 0 then return false end
        local cursor = ffi.cast('uint8_t *', address)
        local remaining = size
        local region = ffi.new('SentryAimMemoryRegion[1]')
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
    -- Private-buffer adapter, also exercised with a synthetic terrain query.
    function api.cast_terrain(raycast,id,unit,origin,target,target_unit,actor_filter)
        local from,to,dir=ffi.new('float[3]'),ffi.new('float[3]'),ffi.new('float[3]')
        assert(#origin==12 and #target==12,'Invalid terrain ray points')
        ffi.copy(from,origin,12);ffi.copy(to,target,12)
        local length=0
        for i=0,2 do
            local delta=tonumber(to[i]-from[i])
            assert(delta==delta and math.abs(delta)<100000,'Invalid terrain ray')
            dir[i]=delta;length=length+delta*delta
        end
        length=math.sqrt(length)
        if length<0.05 then return false end
        assert(length<2000,'Terrain ray outside sentry range')
        for i=0,2 do dir[i]=dir[i]/length end
        assert(id>=0 and id<4,'Invalid physics world')
        -- Match the native static-obstacle preset: closest collection, actor
        -- class 3, damage filter and flags 0x80000009. The native filter admits
        -- only bodies with the static bit. Character/ragdoll volumes, including
        -- initial overlaps around the muzzle, must not act as a firing veto.
        local function query(collection,capacity)
            local out=ffi.new('uint32_t[?]',11*capacity)
            local count=tonumber(raycast(id,from,dir,length,collection,3,0x393d9518,0x80000009,unit,out,capacity))
            assert(count and count>=0 and count==math.floor(count),'Invalid terrain hit count')
            return out,count
        end
        local function classify(out,index)
            local hit=out+11*index
            local distance=tonumber(ffi.cast('float *',hit)[6])
            assert(distance==distance and distance>=0 and distance<=length+0.05,'Invalid terrain hit')
            local hit_unit,actor=tonumber(hit[7]),tonumber(hit[8])
            local detail={hit_unit=hit_unit,hit_actor=actor,target_unit=target_unit,distance=distance,length=length}
            if target_unit and hit_unit==target_unit then detail.reason='target_surface';return false,detail end
            -- A surface endpoint is legal; only geometry before it can veto.
            if distance>=length-0.05 then detail.reason='endpoint';return false,detail end
            detail.filter=actor_filter and actor_filter(actor,hit_unit) or nil
            if detail.filter==0x04a8fbf9 then
                -- Native destructible cover includes fences. A collision here
                -- does not prove that the weapon cannot penetrate/destroy it.
                detail.reason='destructible_cover';return false,detail
            end
            detail.reason='static_obstruction';return true,detail
        end
        local out,count=query(1,1)
        if count==0 then return false,{reason='clear'} end
        local blocked,detail=classify(out,0)
        if detail.reason~='destructible_cover' then return blocked,detail end
        -- Do not ignore the entire unit or stop at its first surface: solid
        -- terrain can sit behind a fence, including within the same unit.
        local capacity=32
        out,count=query(2,capacity)
        local nearest,cover
        for i=0,math.min(count,capacity)-1 do
            local solid,hit=classify(out,i)
            if solid and (not nearest or hit.distance<nearest.distance) then nearest=hit end
            if hit.reason=='destructible_cover' then cover=cover or hit end
        end
        if nearest then return true,nearest end
        -- A truncated result cannot establish obstruction. Leave that case to
        -- native ballistics instead of latching an unproven permanent pause.
        if count>capacity then return false,{reason='cover_query_limit',hits=count} end
        return false,cover or {reason='clear'}
    end
    function api.actor_filter(exe,actor,unit)
        -- Read the native actor/body mapping. Never dereference an unchecked
        -- actor handle or infer cover type from a recycled body index.
        local function uint(b,o)
            if not b then return nil end
            local v=ffi.new('uint32_t[1]');ffi.copy(v,b:sub(o+1,o+4),4);return tonumber(v[0])
        end
        local function ptr(a)return api.pointer(api.read(a,8))end
        local bit=require('bit')
        local world_index=math.floor(actor/0x40000000)
        local pool=exe+0x2369b00+64*(math.floor(actor/0x10000000)%4+10*world_index)
        local h=api.read(pool,56);if not h then return nil end
        local layout=uint(h,28);local stride=layout%65536
        local identity=math.floor(layout/65536)%256;local offset=math.floor(layout/0x1000000)
        local index=bit.band(actor,uint(h,40));local base=api.pointer(h)
        if not base or index<0 or index>=uint(h,36) or bit.band(actor,uint(h,52))==0
            or stride<40 or stride>512 or identity+4>stride or offset+40>stride then return nil end
        local entry=base+index*stride;local key=api.read(entry+identity,4)
        if uint(key,0)~=actor then return nil end
        local record=api.read(entry+offset,40)
        if not record or uint(record,12)~=unit then return nil end
        local world_slot=exe+0x27ba8a8+176*world_index;local world=ptr(world_slot)
        if not world then return nil end
        local bodies=ptr(world+24);local body_index=bit.band(uint(record,20),0xffffff)
        if not bodies or body_index>=262144 then return nil end
        local address=bodies+160*body_index;local body=api.read(address,160)
        if not body or uint(body,144)~=actor or uint(body,148)~=unit then return nil end
        local properties=ptr(exe+0x27c5e48);if not properties then return nil end
        local count=uint(api.read(properties+248,4),0);local names=ptr(properties+256)
        local filter=bit.band(uint(body,108),127)
        if not count or count>128 or filter>=count or not names then return nil end
        local name=api.read(names+4*filter,4)
        if api.read(pool,56)~=h or api.read(entry+identity,4)~=key or api.read(entry+offset,40)~=record
            or ptr(world_slot)~=world or ptr(world+24)~=bodies or api.read(address,160)~=body
            or ptr(exe+0x27c5e48)~=properties or ptr(properties+256)~=names
            or uint(api.read(properties+248,4),0)~=count or api.read(names+4*filter,4)~=name then return nil end
        return uint(name,0)
    end
    function api.bind(game,exe)
        -- Signatures and entity/record identity are checked before each call.
        local flag = ffi.cast('void (*)(void *, uint32_t, uint32_t, uint8_t)',game+0x6bf390)
        local horizontal = ffi.cast('void (*)(void *, float)',game+0x11cba20)
        local vertical = ffi.cast('void (*)(void *, float)',game+0x11cb930)
        local mode = ffi.cast('void (*)(void *, uint32_t, uint32_t)',game+0x755f90)
        local world_id = ffi.cast('uint32_t (*)(const void *)',exe+0x79f860)
        local raycast = ffi.cast('uint32_t (*)(uint32_t, const void *, const void *, float, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void *, uint32_t)',exe+0x7f4590)
        local function ptr(address)
            return assert(api.pointer(api.read(address,8)),'Pose pointer unavailable')
        end
        local function uint(address)
            local b=assert(api.read(address,4),'Pose metadata unavailable')
            local v=ffi.new('uint32_t[1]');ffi.copy(v,b,4);return tonumber(v[0])
        end
        return {
            retention=function(id,enabled) flag(nil,id,2,enabled and 1 or 0) end,
            horizontal=function(entity,speed) horizontal(entity,speed) end,
            vertical=function(entity,speed) vertical(entity,speed) end,
            fire_mode=function(manager,id,value) mode(manager,id,value) end,
            terrain_path=function(unit,origin,target,target_unit)
                -- The native ray workers use this scheduler. Query only after
                -- consumption, using private inputs/output; never enqueue work.
                local scheduler=api.pointer(api.read(game+0x347d7e0,8))
                local world=api.pointer(api.read(game+0x346bfa0,8))
                if not scheduler or not world or uint(scheduler)~=0 then return nil end
                local jobs=api.read(scheduler+0x40008,288)
                if not jobs then return nil end
                local data=ffi.new('uint32_t[72]');ffi.copy(data,jobs,288)
                for i=0,23 do if data[3*i+2]~=1 then return nil end end
                return api.cast_terrain(raycast,tonumber(world_id(world)),unit,origin,target,target_unit,
                    function(actor,owner)return api.actor_filter(exe,actor,owner)end)
            end,
            pose=function(unit,node)
                -- Read the same matrix selected by UnitApi.world_pose, without
                -- invoking an engine virtual function on a possibly stale unit.
                local units=ptr(exe+0x1a100f0);local index=unit%0x400000
                assert(index<uint(units+0x98),'Unit index unavailable')
                local generations=ptr(units+0xa0)
                local generation=string.char(math.floor(unit/0x400000)%256)
                assert(api.read(generations+index,1)==generation,'Unit generation changed')
                local slot=ptr(units+0x88)+8*index;local object=ptr(slot)
                assert(uint(object+8)==unit and node<uint(object+0x70),'Fire node unavailable')
                assert(api.read(ptr(ptr(object)+0xe8),5)=='\x48\x8d\x41\x60\xc3','Unsupported pose layout')
                local matrix=api.read(ptr(object+0x88)+64*node,64)
                assert(ptr(slot)==object and api.read(generations+index,1)==generation,'Pose identity changed')
                return matrix
            end,
        }
    end
    return api
end
