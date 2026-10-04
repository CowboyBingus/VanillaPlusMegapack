-- Windows adapter on top of Bingus Shared Runtime v1. memory is the api of
-- src/bingus_memory.lua extended by src/bingus_write.lua; the build passes it
-- with the core, src/bingus_runtime.lua. The runtime declares the Windows
-- functions under private, versioned names and provides the protection check,
-- checked writes, module handles, module hashes (computed once per session for
-- every mod that asks) and the clock (seconds; it allocates nothing). This file
-- adds what this mod needs: reads at plain-number addresses that allocate
-- nothing but a returned string, pointers as numbers, writes whose destination
-- the caller just checked, its write-size limit and the focus check.
return function(runtime, memory)
    assert(type(memory) == 'table' and type(memory.write) == 'function',
        'bingus_memory.lua and bingus_write.lua v1 are required')
    local native = memory.windows
    local ffi, windows = native.ffi, native.kernel32
    -- Private names (__asm__ labels) and a named function-pointer type,
    -- declared once per process: ffi.cdef keeps the first declaration of a
    -- name for the whole game, and a function-pointer type written in a cast
    -- string would add C types to the table every mod shares on every use.
    if not pcall(ffi.typeof, 'hd2chp_read_memory') then
        ffi.cdef [[
            typedef int (*hd2chp_read_memory)(void *process, uint64_t address, uint64_t buffer, size_t size, uint32_t *done);
            uint32_t hd2chp_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
            int32_t hd2chp_GetForegroundWindow(void) __asm__("GetForegroundWindow");
            uint32_t hd2chp_GetWindowThreadProcessId(intptr_t window, uint32_t *pid) __asm__("GetWindowThreadProcessId");
        ]]
    end
    local kernel, user = ffi.load('kernel32'), ffi.load('user32')
    local process = windows.GetCurrentProcess()
    local api = {distance = memory.distance, module = memory.module, module_hash = memory.module_hash,
        time = memory.time}

    -- Every accepted Windows user address is below 2^47, so a Lua number holds
    -- each byte address exactly.
    function api.address(pointer)
        local value = memory.address(pointer)
        assert(value >= 0x10000 and value < 0x800000000000, 'Address outside bounds')
        return value
    end

    -- The runtime's ReadProcessMemory, cast once to a type whose address and
    -- buffer are uint64_t and whose count is two 32-bit words: a read creates
    -- no pointer or 64-bit cdata. ReadProcessMemory does not call back into Lua.
    local read_memory = ffi.cast('hd2chp_read_memory', windows.ReadProcessMemory)
    local count = ffi.new('uint32_t[2]')
    local function read_to(address, size, destination)
        return read_memory(process, address, destination, size, count) ~= 0 and count[0] == size and count[1] == 0
    end
    -- read(address, size): the bytes as a string (one reused scratch buffer),
    -- so a read allocates only the returned string.
    -- read(address, size, into, offset): the bytes copied into a caller buffer
    -- {data, address, size} at offset, and true: nothing is allocated, which
    -- is what the per-frame snapshot uses. nil when they cannot all be read.
    -- A pointer cdata address is accepted and converted.
    local MAX_READ = 32768
    local scratch = ffi.new('uint8_t[?]', MAX_READ)
    local scratch_address = tonumber(ffi.cast('uintptr_t', scratch))
    function api.read(address, size, into, offset)
        if type(size) ~= 'number' or size < 1 or size > MAX_READ or size % 1 ~= 0 then return nil end
        if type(address) ~= 'number' then address = memory.address(address) end
        if not into then
            if not read_to(address, size, scratch_address) then return nil end
            return ffi.string(scratch, size)
        end
        offset = offset or 0
        if offset < 0 or offset + size > into.size then return nil end
        return read_to(address, size, into.address + offset) or nil
    end

    -- The user-mode pointer stored at bytes[offset+1 .. offset+8], as a number.
    function api.pointer(bytes, offset)
        local value = memory.pointer(bytes, offset)
        return value and memory.address(value)
    end

    -- The largest write is one 280-byte settings record: refuse anything else
    -- before the protection query.
    local MAX_WRITE = 280
    function api.writable_data(address, size)
        return size >= 1 and size <= MAX_WRITE and memory.writable_data(address, size)
    end
    -- checked: the caller verified this destination with writable_data moments
    -- before, in the same call (the settings creation checks all four before
    -- writing any), so the write makes no second query. Any other write is
    -- checked by the runtime right before writing.
    local done = ffi.new('size_t[1]')
    local done32 = ffi.cast('uint32_t *', done)
    function api.write(address, bytes, checked)
        if #bytes < 1 or #bytes > MAX_WRITE then return false end
        local destination = ffi.cast('void *', address)
        if not checked then return memory.write(destination, bytes) end
        return windows.WriteProcessMemory(process, destination, bytes, #bytes, done) ~= 0
            and done32[0] == #bytes and done32[1] == 0
    end

    -- The process ID once per session and one reused output word. A window
    -- handle is 32-bit significant on 64-bit Windows, which documents
    -- truncating it and sign-extending it again: taken as int32_t and passed as
    -- intptr_t, the check creates no pointer cdata.
    local process_id, window_process = kernel.hd2chp_GetCurrentProcessId(), ffi.new('uint32_t[1]')
    function api.focused()
        local window = user.hd2chp_GetForegroundWindow()
        if window == 0 then return false end
        user.hd2chp_GetWindowThreadProcessId(window, window_process)
        return window_process[0] == process_id
    end
    return api
end
