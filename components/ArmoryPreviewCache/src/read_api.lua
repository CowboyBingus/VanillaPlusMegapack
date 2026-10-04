return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Every Windows function has a private name (an __asm__ label naming the
    -- real export). LuaJIT keeps the first prototype declared for a name in the
    -- whole shared state: another mod's declaration of the real names cannot
    -- change the prototypes this mod calls with, and this mod leaves the real
    -- names to the mods that declare them.
    ffi.cdef [[
        void *hd2apc_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        uint32_t hd2apc_GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity)
            __asm__("GetModuleFileNameW");
        void *hd2apc_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int hd2apc_ReadProcessMemory(void *process, const void *address, void *buffer, size_t size,
                                     size_t *read) __asm__("ReadProcessMemory");
        int hd2apc_ReadProcessMemoryTo(void *process, uint64_t address, uint64_t buffer, size_t size,
                                       uint32_t *read) __asm__("ReadProcessMemory");
        void *hd2apc_CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                                 uint32_t disposition, uint32_t flags, void *template_file) __asm__("CreateFileW");
        int hd2apc_ReadFile(void *file, void *buffer, uint32_t size, uint32_t *read, void *overlapped)
            __asm__("ReadFile");
        int hd2apc_CloseHandle(void *handle) __asm__("CloseHandle");
        int32_t hd2apc_BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name,
                                                   const uint16_t *provider, uint32_t flags)
            __asm__("BCryptOpenAlgorithmProvider");
        int32_t hd2apc_BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags)
            __asm__("BCryptCloseAlgorithmProvider");
        int32_t hd2apc_BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                        const void *secret, uint32_t secret_size, uint32_t flags)
            __asm__("BCryptCreateHash");
        int32_t hd2apc_BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags)
            __asm__("BCryptHashData");
        int32_t hd2apc_BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags)
            __asm__("BCryptFinishHash");
        int32_t hd2apc_BCryptDestroyHash(void *hash) __asm__("BCryptDestroyHash");
    ]]
    local kernel, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
    local process = kernel.hd2apc_GetCurrentProcess()
    -- ReadProcessMemoryTo is the same export with the address and destination
    -- as uint64_t (the same register as a pointer on x64) and the byte count
    -- read back as two 32-bit words: a call creates no pointer or 64-bit cdata.
    local read_to = kernel.hd2apc_ReadProcessMemoryTo
    local copied = ffi.new('uint32_t[2]')
    local api = {}

    function api.module(name)
        local handle = kernel.hd2apc_GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    -- read(address, size) returns the bytes as a string. read(address, size,
    -- into, offset) copies them into a caller buffer {data, address, size} at
    -- offset and returns true; address is a number and nothing is allocated,
    -- which is what the per-frame state check uses.
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if type(address) ~= 'number' or offset < 0 or offset + size > into.size then return nil end
            if read_to(process, address, into.address + offset, size, copied) == 0
                or copied[0] ~= size or copied[1] ~= 0 then return nil end
            return true
        end
        local buffer, count = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        if kernel.hd2apc_ReadProcessMemory(process, address, buffer, size, count) == 0 or count[0] ~= size then -- lint-ok: R14 Know Your Constellation copies this reader
            return nil
        end
        return ffi.string(buffer, size)
    end

    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        local value = ffi.new('uintptr_t[1]')
        ffi.copy(value, bytes:sub(offset + 1, offset + 8), 8)
        if value[0] < 0x10000 or value[0] >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value[0])
    end

    function api.module_hash(module)
        local path = ffi.new('uint16_t[32768]')
        local length = kernel.hd2apc_GetModuleFileNameW(module, path, 32768)
        assert(length > 0 and length < 32768, 'Cannot resolve module file')
        local file = kernel.hd2apc_CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
        assert(file ~= ffi.cast('void *', -1), 'Cannot read module file')
        local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
        local ok, result = pcall(function()
            local name = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})
            assert(bcrypt.hd2apc_BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0, 'SHA256 unavailable')
            assert(bcrypt.hd2apc_BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0, 'SHA256 creation failed')
            local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
            while true do
                assert(kernel.hd2apc_ReadFile(file, buffer, 1048576, count, nil) ~= 0, 'Module file read failed')
                if count[0] == 0 then break end
                assert(bcrypt.hd2apc_BCryptHashData(hash[0], buffer, count[0], 0) == 0, 'SHA256 update failed')
            end
            local digest, hex = ffi.new('uint8_t[32]'), {}
            assert(bcrypt.hd2apc_BCryptFinishHash(hash[0], digest, 32, 0) == 0, 'SHA256 finish failed')
            for i = 0, 31 do hex[#hex + 1] = string.format('%02X', digest[i]) end
            return table.concat(hex)
        end)
        if hash[0] ~= nil then bcrypt.hd2apc_BCryptDestroyHash(hash[0]) end
        if algorithm[0] ~= nil then bcrypt.hd2apc_BCryptCloseAlgorithmProvider(algorithm[0], 0) end
        kernel.hd2apc_CloseHandle(file)
        if not ok then error(result) end
        return result
    end
    return api
end
