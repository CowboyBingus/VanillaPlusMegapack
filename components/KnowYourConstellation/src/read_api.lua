return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    -- Every Windows function has a private name, an __asm__ label naming the
    -- real export. ffi.cdef keeps the first prototype declared for a name in the
    -- whole game and ignores later ones without an error, so a mod that declared
    -- a real name first would decide how this mod calls it, and this mod's
    -- declarations would decide it for every mod loaded later.
    -- Memory is addressed by plain numbers: the memory read takes its address
    -- and destination as uint64_t (the same register as a pointer on x64) and
    -- reports its SIZE_T count as two 32-bit words, so a read creates no
    -- pointer or 64-bit cdata. Module files are hashed by the shared runtime
    -- (bingus_memory.lua), once per session for every mod.
    ffi.cdef [[
        void *hd2kyc_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
        void *hd2kyc_GetCurrentProcess(void) __asm__("GetCurrentProcess");
        int hd2kyc_ReadProcessMemory(void *process, uint64_t address, uint64_t buffer, size_t size,
                                     uint32_t *done) __asm__("ReadProcessMemory");
    ]]
    local kernel = ffi.load('kernel32')
    local read_memory = kernel.hd2kyc_ReadProcessMemory
    local process = kernel.hd2kyc_GetCurrentProcess()
    local done = ffi.new('uint32_t[2]')
    local api = {}

    -- The module's base address as a number, or nil.
    function api.module(name)
        local handle = kernel.hd2kyc_GetModuleHandleA(name)
        if handle == nil then return nil end
        return tonumber(ffi.cast('uintptr_t', handle))
    end

    local function copy(address, size, destination)
        return read_memory(process, address, destination, size, done) ~= 0 and done[0] == size and done[1] == 0
    end
    -- Reads size bytes at a number address; nil when they cannot all be read.
    -- read(address, size, into, offset) copies them into a buffer the caller
    -- keeps, into = {data = uint8_t array, address = its address as a number,
    -- size = its length}, at offset and returns true: nothing is allocated.
    -- read(address, size) returns them as a string from one scratch buffer.
    local scratch, scratch_address, scratch_size = nil, nil, 0
    function api.read(address, size, into, offset)
        if into then
            offset = offset or 0
            if size <= 0 or offset < 0 or offset + size > into.size then return nil end
            return copy(address, size, into.address + offset) or nil
        end
        if size > scratch_size then
            scratch_size = math.max(size, 256)
            scratch = ffi.new('uint8_t[?]', scratch_size)
            scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
        end
        if not copy(address, size, scratch_address) then return nil end
        return ffi.string(scratch, size)
    end
    return api
end
