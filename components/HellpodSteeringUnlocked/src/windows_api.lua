return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    ffi.cdef [[
        void *GetModuleHandleA(const char *name);
        uint32_t GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity);
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
        int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
        typedef struct {
            void *base; void *allocation_base; uint32_t allocation_protection;
            uint16_t partition; uint16_t reserved; size_t size;
            uint32_t state; uint32_t protection; uint32_t type;
        } HsuMemoryRegion;
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
        local region = ffi.new('HsuMemoryRegion[1]')
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
    return api
end
