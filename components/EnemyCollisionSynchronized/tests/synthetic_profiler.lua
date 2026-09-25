-- Deterministic hotspot profiler for the synthetic scenes.
-- Where the shipped profiler answers "how long did this poll take", this one
-- answers "which structure did this poll touch, how often, and how much garbage
-- did it leave behind". It wraps the same api.read the mod uses, so it can be
-- installed in the mod's own profiler slot and measure a real poll unchanged.
local ffi = require('ffi')
local P = {}
local STAGES = {discovery=true,snapshot=true,validation=true,planning=true,motion=true,
    native=true,maintenance=true,logging=true,other=true}
local SECTIONS = {'metadata','skeleton','actors','bodies'}
local LIFECYCLES = {corpse_repair=true,corpse_aligned=true,corpse_other=true,ragdoll_settled=true,
    ragdoll_dynamic=true,ragdoll_stopped=true,unclassified=true}
local MAX_SIZES, MAX_ENEMIES, MAX_LIFECYCLES, MAX_FLAGS = 32, 64, 8, 8
local function sorted_keys(rows)
    local keys = {}
    for key in pairs(rows) do keys[#keys+1] = key end
    table.sort(keys)
    return keys
end

function P.new(api, revision, options)
    local settings = options or {}
    local clock = settings.clock or api.clock or api.time
    assert(type(clock)=='function','A clock is required to profile')
    local p = {revision=revision, reads=0, bytes=0, pointer_decodes=0, errors=0,
        polls=0, poll_count=0, total_ms=0, max_ms=0, last_inspected=0, alloc_kb=0, alloc_max_kb=0,
        rows={}, sections={}, classes={}, enemies={}, lifecycles={}, sizes={}, size_keys=0,
        size_overflow=0, flags={}, flag_count=0, gc_held=false, started=0, last_output=0, output_ms=0}
    p.read_start, p.byte_start = 0, 0
    p.started = clock()
    for _, name in ipairs({'discovery','snapshot','validation','planning','motion','native','maintenance','logging','other'}) do
        p.rows[name] = {calls=0,reads=0,bytes=0,ms=0}
    end
    for _, name in ipairs(SECTIONS) do p.sections[name] = {reads=0,bytes=0} end
    -- Regions arrive as half-open numeric ranges in allocation order. Sorting
    -- them makes the classification of every read a bounded binary search.
    p.region_from, p.region_to, p.region_name = {}, {}, {}
    local ordered = {}
    for _, region in ipairs(settings.regions or {}) do ordered[#ordered+1] = region end
    table.sort(ordered, function(a, b) return a.from<b.from end)
    for _, region in ipairs(ordered) do
        p.region_from[#p.region_from+1] = region.from
        p.region_to[#p.region_to+1] = region.to
        p.region_name[#p.region_name+1] = region.name
    end
    local function classify(address)
        local low, high = 1, #p.region_from
        while low<=high do
            local middle = math.floor((low+high)/2)
            if address<p.region_from[middle] then high=middle-1
            elseif address>=p.region_to[middle] then low=middle+1
            else return p.region_name[middle] end
        end
        return 'unknown'
    end
    p.classify = classify
    local function class_row(name)
        local row = p.classes[name]
        if not row then
            row = {reads=0,bytes=0,max_size=0}
            p.classes[name] = row
        end
        return row
    end
    local function note_size(size)
        if p.sizes[size] then p.sizes[size] = p.sizes[size]+1
        elseif p.size_keys<MAX_SIZES then p.size_keys = p.size_keys+1;p.sizes[size] = 1
        else p.size_overflow = p.size_overflow+1 end
    end
    function p.flag(name)
        for i=1,p.flag_count do if p.flags[i]==name then return end end
        if p.flag_count<MAX_FLAGS then
            p.flag_count = p.flag_count+1;p.flags[p.flag_count] = name
        end
    end
    local function close_phase(now)
        if p.running and p.current then
            p.rows[p.current].ms = p.rows[p.current].ms+(now-p.phase_at)*1000
        end
        p.phase_at = now
    end
    function p.phase(name)
        local old = p.current
        if p.running and name and STAGES[name] then
            local now = clock()
            close_phase(now)
            p.current = name
            p.rows[name].calls = p.rows[name].calls+1
        end
        return old
    end
    function p.detail(name)
        if not p.running or p.current~='snapshot' or not p.sections[name] then return end
        p.detail_current = name
    end
    function p.begin(state)
        p.running = true
        p.current = 'maintenance'
        p.rows.maintenance.calls = p.rows.maintenance.calls+1
        p.read_start, p.byte_start = p.reads, p.bytes
        p.poll_reads, p.poll_bytes = p.reads, p.bytes
        p.detail_current = nil
        p.block_reads, p.block_bytes = p.reads, p.bytes
        p.deep_start = state and state.deep_inspections or 0
        p.phase_at = clock()
        p.block_at = p.phase_at
        p.started_at = p.phase_at
        if p.gc_held then p.heap_start = collectgarbage('count') end
    end
    function p.finish(state)
        local now = clock()
        close_phase(now)
        p.running = false
        p.current = nil
        local elapsed = (now-p.started_at)*1000
        p.polls = p.polls+1
        p.poll_count = p.polls
        p.total_ms = p.total_ms+elapsed
        p.max_ms = math.max(p.max_ms,elapsed)
        p.last_inspected = (state and state.deep_inspections or 0)-(p.deep_start or 0)
        p.unattributed_reads = (p.unattributed_reads or 0)+(p.reads-(p.block_reads or p.reads))
        p.unattributed_bytes = (p.unattributed_bytes or 0)+(p.bytes-(p.block_bytes or p.bytes))
        p.block_reads, p.block_bytes = nil, nil
        if p.gc_held and p.heap_start then
            local used = collectgarbage('count')-p.heap_start
            p.alloc_max_kb = math.max(p.alloc_max_kb,used)
        end
        if elapsed>2 then p.flag('slow_poll') end
        if settings.max_units_hint and p.last_inspected>settings.max_units_hint then
            p.flag('inspection_over_budget')
        end
        p.started_at = nil
    end
    function p.unit(name,start,reads,unit)
        if not p.running then return end
        local row = p.enemies[name]
        if not row then
            if #sorted_keys(p.enemies)>=MAX_ENEMIES then return end
            row = {inspections=0,reads=0,bytes=0,ms=0}
            p.enemies[name] = row
        end
        row.inspections = row.inspections+1
        -- The mod reports one unit at a time, so the reads and bytes observed
        -- since the previous report are exactly this unit's scan, inspection and
        -- consume cost. Nothing has to be guessed from the reported arguments.
        row.reads = row.reads+(p.reads-(p.block_reads or p.reads))
        row.bytes = row.bytes+(p.bytes-(p.block_bytes or p.bytes))
        p.block_reads, p.block_bytes = p.reads, p.bytes
        -- Time the block here rather than trusting the caller's start argument:
        -- the mod passes its own work clock, which is not the profiler's clock.
        local now = clock()
        row.ms = row.ms+(now-(p.block_at or now))*1000
        p.block_at = now
        if type(unit)=='table' then
            local kind = unit.profile_lifecycle
            if not LIFECYCLES[kind] then kind = unit.profile_lifecycle and 'unclassified' or nil end
            if kind then
                local life = p.lifecycles[kind]
                if not life then
                    if #sorted_keys(p.lifecycles)<MAX_LIFECYCLES then
                        life = {inspections=0}
                        p.lifecycles[kind] = life
                    end
                end
                if life then life.inspections = life.inspections+1 end
            end
        end
    end
    function p.update_started()
        local now = clock()
        p.updates = (p.updates or 0)+1
        return now
    end
    function p.update_finished(start,ok)
        if not start then return end
        p.update_ms = (p.update_ms or 0)+(clock()-start)*1000
        if not ok then p.update_errors = (p.update_errors or 0)+1 end
    end
    function p.report()
        local lines = {string.format('synthetic revision=%s polls=%d',tostring(p.revision),p.polls)}
        lines[#lines+1] = string.format('total reads=%d bytes=%d pointer_decodes=%d errors=%d alloc_kb=%.3f alloc_max_poll_kb=%.3f',
            p.reads,p.bytes,p.pointer_decodes,p.errors,p.alloc_kb,p.alloc_max_kb)
        lines[#lines+1] = string.format('timing total_ms=%.4f mean_ms=%.4f max_ms=%.4f update_ms=%.4f last_inspected=%d',
            p.total_ms,p.total_ms/math.max(1,p.polls),p.max_ms,p.update_ms or 0,p.last_inspected)
        for _, name in ipairs(sorted_keys(p.rows)) do
            local row = p.rows[name]
            lines[#lines+1] = string.format('phase=%s calls=%d reads=%d bytes=%d ms=%.4f',
                name,row.calls,row.reads,row.bytes,row.ms)
        end
        for _, name in ipairs(sorted_keys(p.sections)) do
            local row = p.sections[name]
            lines[#lines+1] = string.format('section=%s reads=%d bytes=%d',name,row.reads,row.bytes)
        end
        for _, name in ipairs(sorted_keys(p.classes)) do
            local row = p.classes[name]
            lines[#lines+1] = string.format('class=%s reads=%d bytes=%d max_read=%d reads_per_poll=%.2f bytes_per_poll=%.1f',
                name,row.reads,row.bytes,row.max_size,row.reads/math.max(1,p.polls),row.bytes/math.max(1,p.polls))
        end
        local sizes = {}
        for size in pairs(p.sizes) do if type(size)=='number' then sizes[#sizes+1]=size end end
        table.sort(sizes)
        for _, size in ipairs(sizes) do lines[#lines+1] = string.format('size=%d count=%d',size,p.sizes[size]) end
        if p.size_overflow>0 then lines[#lines+1] = string.format('size=overflow count=%d',p.size_overflow) end
        for _, name in ipairs(sorted_keys(p.enemies)) do
            local row = p.enemies[name]
            lines[#lines+1] = string.format('enemy=%s inspections=%d reads=%d bytes=%d ms=%.4f',
                name,row.inspections,row.reads,row.bytes,row.ms)
        end
        for _, name in ipairs(sorted_keys(p.lifecycles)) do
            local row = p.lifecycles[name]
            lines[#lines+1] = string.format('lifecycle=%s inspections=%d',name,row.inspections)
        end
        lines[#lines+1] = string.format('unattributed reads=%d bytes=%d',
            p.unattributed_reads or 0,p.unattributed_bytes or 0)
        if p.flag_count>0 then lines[#lines+1] = 'flags='..table.concat(p.flags,',') end
        return table.concat(lines,'\n')..'\n'
    end
    function p.text(state)
        state = state or {}
        return p.report()..string.format('scope_mission=%s observed=%d read_calls=%d read_bytes=%d\n',
            tostring(state.mission_flag==1),tonumber(state.observed) or 0,
            tonumber(state.read_calls) or 0,tonumber(state.read_bytes) or 0)
    end
    function p.flush(state,force)
        local now = clock()
        if p.last_output~=0 and not force and now-p.last_output<10 then return end
        p.last_output = now
        local started = clock()
        pcall(function()
            local logger = rawget(_G,'CowboyBingusModLoader')
            local file = logger and logger.open_log and logger.open_log('EnemyCollisionSynchronized-Synthetic.log')
            if not file then return end
            file:write(p.text(state))
            file:close()
        end)
        p.output_ms = math.max(p.output_ms,(clock()-started)*1000)
    end
    function p.hold_gc()
        if p.gc_held then return end
        collectgarbage('collect')
        collectgarbage('stop')
        p.gc_held = true
        p.gc_base = collectgarbage('count')
    end
    function p.release_gc()
        if not p.gc_held then return end
        p.alloc_kb = p.alloc_kb+(collectgarbage('count')-p.gc_base)
        p.gc_held = false
        collectgarbage('restart')
    end
    -- Allocation is only attributable while the collector is held: a running
    -- collector can return memory at any moment and hide the cost entirely.
    function p.allocated_kb(fn)
        local start = collectgarbage('count')
        local ok, message = pcall(fn)
        local used = collectgarbage('count')-start
        -- release_gc accounts for the whole held interval, including this call.
        if not ok then error(message,0) end
        return used
    end
    local read = api.read
    -- Unlike the shipped telemetry, reads are counted whether or not a poll is
    -- open: a structure the mod touches outside begin/finish still costs time,
    -- and a measurement that silently dropped it would under-report the total.
    api.read = function(address,size)
        p.reads = p.reads+1;p.bytes = p.bytes+size
        local class = classify(tonumber(ffi.cast('uintptr_t',address)))
        local row = p.classes[class]
        if not row then row = class_row(class) end
        row.reads = row.reads+1;row.bytes = row.bytes+size
        if size>row.max_size then row.max_size = size end
        note_size(size)
        local stage = p.rows[p.current or 'other']
        stage.reads = stage.reads+1;stage.bytes = stage.bytes+size
        local section = p.running and p.current=='snapshot' and p.detail_current and p.sections[p.detail_current]
        if section then section.reads = section.reads+1;section.bytes = section.bytes+size end
        return read(address,size)
    end
    -- Views are reads for every count here, and stay paired with the wrapped read.
    local view = api.view
    if view and api.view_read==read then
        api.view = function(address,size)
            p.reads = p.reads+1;p.bytes = p.bytes+size
            local class = classify(tonumber(ffi.cast('uintptr_t',address)))
            local row = p.classes[class]
            if not row then row = class_row(class) end
            row.reads = row.reads+1;row.bytes = row.bytes+size
            if size>row.max_size then row.max_size = size end
            note_size(size)
            local stage = p.rows[p.current or 'other']
            stage.reads = stage.reads+1;stage.bytes = stage.bytes+size
            local section = p.running and p.current=='snapshot' and p.detail_current and p.sections[p.detail_current]
            if section then section.reads = section.reads+1;section.bytes = section.bytes+size end
            return view(address,size)
        end
        api.view_read = api.read
    end
    if type(api.pointer)=='function' then
        -- Pointer decoding is pure LuaJIT arithmetic but happens several times
        -- per read, so it stays visible to the hotspot report.
        local pointer = api.pointer
        api.pointer = function(...)
            p.pointer_decodes = p.pointer_decodes+1
            return pointer(...)
        end
    end
    -- Install into the mod's own telemetry slot, exactly as the loader does, so
    -- every scenario gets phase, section and per-enemy attribution for free.
    api.profiler = p
    return p
end

return P
