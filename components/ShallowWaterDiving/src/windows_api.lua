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
        } SwdMemoryRegion;
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
        typedef size_t (*SwdQueryRegion)(const void *address, void *region, size_t size);
        typedef int (*SwdReadMemory)(void *process, uint64_t address, uint64_t buffer, size_t size, uint32_t *read);
        typedef int (*SwdWriteMemory)(void *process, uint64_t address, const void *buffer, size_t size, uint32_t *written);
    ]]
    local kernel, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
    -- LuaJIT retains the first function declaration in the shared VM. Use an
    -- opaque buffer when declaring first so another mod's equivalent struct is
    -- accepted. Cast our own call as well for a typed declaration loaded first.
    -- The casts use the named types above: a function pointer written out in a
    -- type string adds C types to the table all mods share on every use.
    local query_region = ffi.cast('SwdQueryRegion', kernel.VirtualQuery)
    -- Memory is addressed by plain numbers: these casts take the address and
    -- destination as uint64_t (the same register as a pointer on x64) and the
    -- byte count as two 32-bit words, so a call creates no pointer or 64-bit
    -- cdata. Neither call re-enters Lua before its count words are read.
    local read_memory = ffi.cast('SwdReadMemory', kernel.ReadProcessMemory)
    local write_memory = ffi.cast('SwdWriteMemory', kernel.WriteProcessMemory)
    local process = kernel.GetCurrentProcess()
    local api = {}
    function api.time() return tonumber(kernel.GetTickCount64()) / 1000 end

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    -- read(address, size) returns the bytes as a string (one scratch buffer,
    -- grown on demand). read(address, size, into, offset) copies them into a
    -- caller buffer {data, address, size} at offset and returns true: nothing
    -- is allocated, which is what the per-frame snapshot uses.
    local scratch_size, scratch = 4096, ffi.new('uint8_t[4096]')
    local scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if size <= 0 or offset < 0 or offset + size > into.size then return nil end
            return read_to(address, size, into.address + offset) or nil
        end
        if size < 0 or size > scratch_size then
            scratch, scratch_size = ffi.new('uint8_t[?]', size), size
            scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
        end
        if not read_to(address, size, scratch_address) then return nil end
        return ffi.string(scratch, size)
    end

    local written, region = ffi.new('uint32_t[2]'), ffi.new('SwdMemoryRegion[1]')
    -- checked: the caller verified this range with writable_data and decides
    -- how long that check stays valid. Otherwise the write checks its page.
    function api.write(address, bytes, checked)
        if not checked and not api.writable_data(address, #bytes) then return false end
        return write_memory(process, address, bytes, #bytes, written) ~= 0 and written[0] == #bytes and written[1] == 0
    end

    function api.distance(first, second)
        return tonumber(ffi.cast('intptr_t', first) - ffi.cast('intptr_t', second))
    end

    -- True, and the span [low, high) of whole regions it checked, when every
    -- page of [address, address + size) is committed private read/write data.
    -- Each VirtualQuery costs about 0.2-0.3 ms in game; api.queries counts them.
    api.queries = 0
    function api.writable_data(address, size)
        if size <= 0 then return false end
        local cursor = ffi.cast('uint8_t *', address)
        local remaining, low, high = size, nil, nil
        while remaining > 0 do
            api.queries = api.queries + 1
            if query_region(cursor, region, ffi.sizeof(region[0])) ~= ffi.sizeof(region[0]) then return false end
            -- Settings must already be writable private data, never executable or mapped module pages.
            if region[0].state ~= 0x1000 or region[0].type ~= 0x20000 or region[0].protection ~= 4 then return false end
            local available = tonumber(region[0].size) - api.distance(cursor, region[0].base)
            if available <= 0 then return false end
            local base = tonumber(ffi.cast('uintptr_t', region[0].base))
            low, high = low or base, base + tonumber(region[0].size)
            local step = math.min(available, remaining)
            cursor, remaining = cursor + step, remaining - step
        end
        return true, low, high
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
