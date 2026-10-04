return function(base)
    local ffi=require('ffi')
    -- Private names with __asm__ labels, as in read_api.lua: another mod's
    -- declaration of the real names cannot change these prototypes.
    ffi.cdef[[
        uint64_t hd2apc_GetTickCount64(void) __asm__("GetTickCount64");
        uint32_t hd2apc_GetTickCount(void) __asm__("GetTickCount");
        uint32_t hd2apc_GetCurrentThreadId(void) __asm__("GetCurrentThreadId");
        uint32_t hd2apc_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
        int hd2apc_GetProcessTimes(void *,void *,void *,void *,void *) __asm__("GetProcessTimes");
        int hd2apc_GlobalMemoryStatusEx(void *status) __asm__("GlobalMemoryStatusEx");
        int hd2apc_K32GetProcessMemoryInfo(void *process,void *counters,uint32_t size) __asm__("K32GetProcessMemoryInfo");
    ]]
    local kernel=ffi.load('kernel32');local api=base()
    local main_thread=kernel.hd2apc_GetCurrentThreadId()
    -- GetTickCount64's 64-bit result is boxed as cdata on every interpreted
    -- call. GetTickCount returns the low 32 bits of the same tick count as a
    -- plain number; the high word is carried here (it changes every 49.7 days).
    local ticks=tonumber(kernel.hd2apc_GetTickCount64())
    local tick_high,tick_low=math.floor(ticks/4294967296),ticks%4294967296
    function api.time()
        local low=kernel.hd2apc_GetTickCount()
        if low<tick_low then tick_high=tick_high+1 end
        tick_low=low
        return (tick_high*4294967296+low)/1000
    end
    function api.assert_thread()assert(kernel.hd2apc_GetCurrentThreadId()==main_thread,'Wrong update thread')end
    local process=kernel.hd2apc_GetCurrentProcess()
    local process_times=ffi.new('uint64_t[4]')
    assert(kernel.hd2apc_GetProcessTimes(process,process_times,process_times+1,process_times+2,process_times+3)~=0)
    api.process_id=tonumber(kernel.hd2apc_GetCurrentProcessId())
    local creation_words=ffi.cast('uint32_t *',process_times)
    api.process_created_filetime_hex=string.format('%08x%08x',tonumber(creation_words[1]),tonumber(creation_words[0]))
    -- Both structures are filled by the calls below and read back through
    -- one 32-bit view each: 64-bit fields decode from two halves, so a poll
    -- creates no cdata.
    local memory=ffi.new('uint64_t[8]');local process_memory=ffi.new('uint64_t[10]')
    local memory_words=ffi.cast('uint32_t *',memory);local process_words=ffi.cast('uint32_t *',process_memory)
    local function qword(words,index)return words[index*2]+words[index*2+1]*4294967296 end
    -- Bound once; the private prototypes need no cast. Never cast per poll:
    -- anonymous function ctypes are not collected by LuaJIT, and per-poll
    -- casts exhausted its type table after about 8,163 memory polls.
    local global=kernel.hd2apc_GlobalMemoryStatusEx
    local private=kernel.hd2apc_K32GetProcessMemoryInfo
    function api.memory()
        memory_words[0]=64;process_words[0]=80
        assert(global(memory)~=0 and private(process,process_memory,80)~=0,'Memory telemetry unavailable')
        -- MEMORYSTATUSEX: available physical RAM at +16, available commit at +32.
        return qword(memory_words,2),qword(process_words,9),qword(memory_words,4)
    end
    local original=api.read
    function api.read(address,size,into,offset)
        if type(size)~='number' or size<1 or size>32768 or size%1~=0 then return nil end
        return original(address,size,into,offset)
    end
    return api
end
