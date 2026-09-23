-- HD2-Addon: mods/cowboybingus/arc_thrower_auto

-- ARC-3 Arc Thrower: hold the fire button and the weapon keeps firing.
-- Vanilla fires once per press and release; this addon lets the engine's own
-- charge -> fire cycle repeat while the button stays down. Nothing else is
-- changed: charge times, cadence, damage and arc settings stay stock.

-- Re-entry guard: deploying the standalone addon and a pack that bundles it
-- together must not install the assist twice.
if rawget(_G, 'ArcThrowerRevampedInstalled') then return end
rawset(_G, 'ArcThrowerRevampedInstalled', true)

local module = {revision = 'v1.5'}

local ffi = require('ffi')
local bit = require('bit')


-- Resolved on first use, so the addon loads inert in any environment
-- and a failed binding only leaves the assist idle.
local kernel

-- Build 25327279 anchors. The charge manager holds one 40-byte entry per
-- weapon; entry + 4 is the charge, + 8 its full-charge time, + 12 the flag the
-- engine's charge updater advances while set.
local CHARGE_MANAGER = 0x3326c20
local TRIGGER_MANAGER = 0x3326660
local FIRE_MODE_SETTER = 0x755f90
local FIRE_MODE_SIGNATURE = '\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
local ARC_FINGERPRINT = '\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41'
local ARC_RESOURCE = '\xe6\x06\x73\x0f\xd5\x9c\xde\x96'
local AUTO_FIRE_FLAG = 184
local ENTRY_SIZE = 40
local POINTER_SIZE = 8
local RECOVERY_WINDOW = 0.25
local TRIGGER_BATCH, TRIGGER_LIMIT = 64, 4096
local MEM_COMMIT, MEM_PRIVATE, PAGE_READONLY, PAGE_READWRITE = 0x1000, 0x20000, 0x02, 0x04

local state = {armed = false, patched = false, record = nil, scans = 0,
               checked = false, supported = false, resolved = nil,
               previous = nil, shots = {}, last_shot = nil, status = nil,
               status_charge = nil, errors = 0, reason = nil, reason_log = nil,
               reason_time = nil, drove_since = nil, drove_peak = 0, rescans = 0}

local performance_frequency = ffi.new('int64_t[1]')
local performance_counter = ffi.new('int64_t[1]')

local function bind()
    if state.bound then return true end
    if state.bind_error then return false end
    local ok, problem = pcall(function()
        -- Declare before lookup; native LuaJIT functions are callable cdata.
        ffi.cdef [[void *GetModuleHandleA(const char *name);]]
        kernel = ffi.load('kernel32')
        local game = kernel.GetModuleHandleA('game.dll')
        if game == nil then error('game.dll not loaded') end
        state.game = tonumber(ffi.cast('uint64_t', game))
        -- Declared here, not at load: repeating cdef in every
        -- environment exhausts LuaJIT's CType table.
        ffi.cdef [[
        typedef unsigned char uint8_t;
        typedef unsigned short uint16_t;
        typedef unsigned int uint32_t;
        typedef unsigned long long uint64_t;
        typedef struct {
            void *BaseAddress;
            void *AllocationBase;
            uint32_t AllocationProtect;
            uint16_t PartitionId;
            uint16_t Padding1;
            size_t RegionSize;
            uint32_t State;
            uint32_t Protect;
            uint32_t Type;
            uint32_t Padding2;
        } MEMORY_BASIC_INFORMATION;
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *process, const void *base, void *buffer, size_t size, size_t *read);
        int WriteProcessMemory(void *process, void *base, const void *buffer, size_t size, size_t *written);
        int VirtualProtectEx(void *process, void *address, size_t size, uint32_t protect, uint32_t *previous);
        int VirtualQueryEx(void *process, const void *address, MEMORY_BASIC_INFORMATION *info, size_t length);
        uint64_t GetTickCount64(void);
        int QueryPerformanceCounter(int64_t *count);
        int QueryPerformanceFrequency(int64_t *frequency);
        ]]
        state.process = kernel.GetCurrentProcess()
        kernel.QueryPerformanceFrequency(performance_frequency)
    end)
    if not ok then
        state.bind_error = tostring(problem)
        return false
    end
    state.bound = true
    return true
end

local function seconds()
    if not state.bound then return 0 end
    kernel.QueryPerformanceCounter(performance_counter)
    return tonumber(performance_counter[0]) / tonumber(performance_frequency[0])
end

local loader = rawget(_G, 'CowboyBingusModLoader')
local log = nil
if loader and type(loader.open_log) == 'function' then
    log = loader.open_log('ArcThrowerAuto.log')
end

local function note(message)
    if log then log:write(message .. '\n'); log:flush() end
end

local function log_line(message)
    if not rawget(_G, 'ArcThrowerDiagnostics') then return end
    if not kernel then return note(message) end
    note(string.format('[%8.3f] %s', tonumber(kernel.GetTickCount64()) / 1000 % 100000,
                       message))
end

local function read(address, size)
    local buffer = ffi.new('uint8_t[?]', size)
    local got = ffi.new('size_t[1]')
    if not state.bound then return nil end
    if kernel.ReadProcessMemory(state.process, ffi.cast('void *', address), buffer, size,
                                got) == 0 then
        return nil
    end
    if got[0] ~= size then return nil end
    return ffi.string(buffer, size)
end

local function write(address, data)
    local written = ffi.new('size_t[1]')
    if not state.bound then return false end
    return kernel.WriteProcessMemory(state.process, ffi.cast('void *', address),
                                     ffi.cast('const void *', data), #data,
                                     written) ~= 0 and written[0] == #data
end

local function write_protected(address, data)
    local previous = ffi.new('uint32_t[1]')
    if not state.bound then return false end
    if kernel.VirtualProtectEx(state.process, ffi.cast('void *', address), #data,
                               PAGE_READWRITE, previous) == 0 then
        return false
    end
    local ok = write(address, data)
    local restored = ffi.new('uint32_t[1]')
    kernel.VirtualProtectEx(state.process, ffi.cast('void *', address), #data,
                            previous[0], restored)
    return ok
end

local function unpack(blob, fmt, offset)
    local value = ffi.new(fmt .. '[1]')
    ffi.copy(value, blob:sub(offset + 1, offset + ffi.sizeof(value)), ffi.sizeof(value))
    return tonumber(value[0])
end

local function u32(blob, offset) return unpack(blob, 'uint32_t', offset) end
local function u64(blob, offset) return unpack(blob, 'uint64_t', offset) end
local function f32(blob, offset) return unpack(blob, 'float', offset) end

local function pointer(address)
    local blob = read(address, POINTER_SIZE)
    if not blob then return nil end
    return u64(blob, 0)
end

-- Resolve the local avatar through both registries, including its generation.
-- Slot 9 is the native Fire action (pair 2,9), after input rebinding/controller
-- processing; +8 is held time. Aim is slot 8 and must not drive this assist.
local function lookup(header, key, limit)
        if not header then return nil end
        local data,cap,empty,mult=u64(header,0),u32(header,8),u32(header,12),u32(header,16)
        if data==0 or cap==0 or cap>limit or bit.band(cap,cap-1)~=0 then return nil end
        local product=tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',key)*ffi.new('uint64_t',mult)))
        for probe=0,math.min(cap,64)-1 do
            local row=read(data+8*bit.band(product+probe,cap-1),8)
            if not row then return nil end
            if u32(row,0)==key then local index=u32(row,4);if index~=0xffffffff then return index end;return nil end
            if u32(row,0)==empty then return nil end
        end
end
local function local_fire()
    local pm,owner,am=pointer(state.game+0x3326468),pointer(state.game+0x346bf98),pointer(state.game+0x3326d20)
    if not pm or pm==0 or not owner or owner==0 or not am or am==0 then return nil end
    local counts,unit=read(pm+0x84,8),read(pm+0x3a8,4)
    if not counts or not unit or u32(counts,0)<1 or u32(counts,0)>4
        or u32(counts,4)<1 or u32(counts,4)>4 or u32(unit,0)==0x7fff then return nil end
    local player=pointer(pm+0xe8)
    local player_record=player and player~=0 and read(player,24)
    if not player_record or bit.band(player_record:byte(21),1)==0 then return nil end
    local ei=lookup(read(owner+0xf22ec8,20),u32(unit,0),1048576)
    if not ei or ei>=262144 then return nil end
    local avatar=read(owner+0xf32f18+ei*24,24)
    if not avatar or avatar:sub(1,8)~='\x97\xfa\x4d\x29\x4d\x33\x1c\x4d'
        or bit.band(avatar:byte(21),1)==0 then return nil end
    local ai=lookup(read(am+0xf8,20),u32(avatar,8),64)
    local count=read(am+0x6c,4)
    if not ai or not count or u32(count,0)>8 or ai>=u32(count,0) then return nil end
    local entity=pointer(am+0x110+ai*8)
    if not entity or entity==0 or read(entity,24)~=avatar then return nil end
    local input=read(am+0x150+ai*0xa7aec+0x1b68+9*32,32)
    if not input then return nil end
    local held=f32(input,8)
    if held~=held or held<0 or held>=86400 then return nil end
    return held>0,avatar,held
end

local function local_weapon(record,avatar)
    local manager=pointer(state.game+0x3326dc0)
    if not manager or manager==0 then return nil end
    local index=lookup(read(manager+32,20),u32(record,8),8192)
    if not index or index>=4096 then return nil end
    local rows=pointer(manager+64)
    local holder=rows and rows~=0 and read(rows+index*48+4,4)
    if not holder then return nil end
    return u32(holder,0)==u32(avatar,8)
end

-- Entry arrays can move or compact while fire stays held. Check the slot every
-- update; only search the bounded pointer array when its binding changed.
local function charge_entry(chosen)
    local manager=pointer(state.game+CHARGE_MANAGER)
    if not manager or manager==0 then return nil end
    local header=read(manager+16,56)
    if not header then return nil end
    local count,entities,entries=u32(header,0),u64(header,40),u64(header,48)
    if count<1 or count>512 or entities==0 or entries==0 then return nil end
    if chosen.index and chosen.index<count and pointer(entities+chosen.index*8)==chosen.entity then
        return entries+chosen.index*ENTRY_SIZE
    end
    local pointers=read(entities,count*8)
    if not pointers then return nil end
    for index=0,count-1 do
        if u64(pointers,index*8)==chosen.entity then
            chosen.index=index
            return entries+index*ENTRY_SIZE
        end
    end
    return false -- readable table confirms this weapon is no longer charged
end

local function supported_build()
    if state.checked then return state.supported end
    state.checked = true
    local game = kernel.GetModuleHandleA('game.dll')
    if game == nil then return false end
    local base = tonumber(ffi.cast('uint64_t', game))
    state.supported = read(base + FIRE_MODE_SETTER, #FIRE_MODE_SIGNATURE)
        == FIRE_MODE_SIGNATURE
    return state.supported
end

-- The weapon data library is one large read-only private allocation. The arc
-- thrower's charge record is located by its animation-variable fingerprint;
-- auto_fire_in_safety tells the engine it may complete the shot itself.
local function valid_charge_record(charge)
    return charge and charge:sub(169,184)==ARC_FINGERPRINT
        and math.abs(f32(charge,0)-1.0)<1e-3
        and math.abs(f32(charge,24)-1.1)<1e-3
        and math.abs(f32(charge,48)-1.2)<1e-3
        and math.abs(f32(charge,72)-0.7)<1e-3
        and math.abs(f32(charge,76)-1.4)<1e-3
end

local function ensure_auto_fire(record, charge)
    if charge:byte(AUTO_FIRE_FLAG+1)==1 then return true end
    local ok=write_protected(record+AUTO_FIRE_FLAG,'\x01')
        and read(record+AUTO_FIRE_FLAG,1)=='\x01'
    if ok then log_line(string.format('auto-fire flag restored at %#x',record)) end
    return ok
end

local function scan_charge_record()
    local information = ffi.new('MEMORY_BASIC_INFORMATION')
    local address = 0
    local limit = 0x7FFFFFFFFFFF
    while address < limit do
        coroutine.yield(0) -- bound region queries as well as data reads
        if kernel.VirtualQueryEx(state.process, ffi.cast('const void *', address),
                                 information, ffi.sizeof(information)) == 0 then
            return false, 'VirtualQueryEx failed'
        end
        local base = tonumber(ffi.cast('uint64_t', information.BaseAddress))
        local size = tonumber(information.RegionSize)
        if information.State == MEM_COMMIT and information.Protect == PAGE_READONLY
           and information.Type == MEM_PRIVATE and size >= 0x100000 then
            local offset = 0
            while offset < size do
                local span = math.min(65536, size - offset)
                local blob = read(base + offset, span)
                coroutine.yield(span)
                if blob then
                    local start = 1
                    while true do
                        local found = blob:find(ARC_FINGERPRINT, start, true)
                        if not found then break end
                        local record = base + offset + found - 1 - 168
                        local charge = read(record, 216)
                        -- A recovery scan must pass already-patched copies to
                        -- find a replacement, even if the old allocation lives on.
                        if valid_charge_record(charge)
                           and (not state.patched or charge:byte(AUTO_FIRE_FLAG+1)~=1) then
                            state.record = record
                            state.patched=ensure_auto_fire(record,charge)
                            if state.patched then
                                return true
                            end
                            return false, 'charge record write failed'
                        end
                        start = found + 1
                        coroutine.yield(0) -- malformed candidates also consume a work slice
                    end
                end
                -- Overlap keeps a fingerprint crossing a chunk boundary visible.
                offset = offset + (offset + span < size and span - #ARC_FINGERPRINT + 1 or span)
            end
        end
        address = base + size
        if address <= 0 then break end
    end
    return false, 'charge record not found'
end

-- One update may examine at most 16 scan steps / 256 KiB, with a soft
-- one-millisecond deadline. A native read already in flight is not preemptible.
local scan_thread, next_scan = nil, 0
local function patch_charge_record(now)
    if now < next_scan then return false, 'waiting' end
    if not scan_thread then
        state.rescan_requested = nil
        scan_thread = coroutine.create(scan_charge_record)
        state.scans = state.scans + 1
    end
    local bytes, deadline = 0, seconds() + 0.001
    for _ = 1, 16 do
        local ok, result, reason = coroutine.resume(scan_thread)
        if not ok then
            scan_thread, next_scan = nil, now + 5
            return false, 'scan failed'
        end
        if coroutine.status(scan_thread) == 'dead' then
            scan_thread, next_scan = nil, now + (result and 1 or 5)
            return result, reason
        end
        bytes = bytes + (result or 0)
        if bytes >= 262144 or seconds() >= deadline then break end
    end
    return false, 'pending'
end

local function maintain_charge_record(now)
    if state.record and now >= (state.next_record_check or 0) then
        state.next_record_check=now+0.25
        local charge=read(state.record,216)
        if valid_charge_record(charge) then
            state.patched=ensure_auto_fire(state.record,charge)
            if not state.patched then log_line('charge record repair failed; retrying') end
        else
            -- Never write through an expired/reused record address.
            state.record=nil;state.patched=false
            scan_thread=nil;next_scan=now
            log_line('charge record unavailable or changed; rediscovering')
        end
    end
    if not state.patched or state.rescan_requested or scan_thread then
        local ok,reason=patch_charge_record(now)
        if ok then
            if not state.patch_logged then note('Charge record ready.');state.patch_logged=true end
        elseif not state.patched and reason~='pending' and reason~='waiting' and not state.scan_logged then
            state.scan_logged=true
            note('Charge record not ready yet: '..tostring(reason))
        end
    end
end

-- Inspect the small fire-command table first. Ordinary weapons never trigger
-- a walk of every charged weapon. Charge-table lookup is needed only to arm
-- an Arc Thrower that the engine is actually firing.
local function active_arc(avatar)
    local manager = pointer(state.game + TRIGGER_MANAGER)
    if not manager or manager == 0 then return nil end
    local header = read(manager + 24, 72)
    if not header then return nil end
    local count, entities, held = u32(header, 0), u64(header, 40), u64(header, 64)
    state.trigger_count=count
    if count < 1 or count > TRIGGER_LIMIT or entities == 0 or held == 0 then
        return nil,'invalid trigger table (count '..tostring(count)..')'
    end
    -- Read the small flag array first so a sparse table's last slot is found
    -- before the first shot clears its command. Inspect at most 64 active
    -- candidates per discovery; dense tables continue in the next batch.
    if state.discovery_entities~=entities or state.discovery_count~=count then
        state.discovery_index=0
        state.discovery_entities=entities;state.discovery_count=count
    end
    local first=state.discovery_index or 0
    local flags=read(held,count)
    if not flags then return nil end
    state.discovery_index=0
    local chosen,examined=nil,0
    for offset = 0, count - 1 do
        local index=(first+offset)%count
        if flags:byte(index + 1) ~= 0 then
            local entity = pointer(entities+index*POINTER_SIZE)
            local record = entity and entity ~= 0 and read(entity, 24)
            if record and record:sub(1, 8) == ARC_RESOURCE and bit.band(record:byte(21), 1) == 1
                and local_weapon(record,avatar) then
                chosen = {entity=entity,identity=record}
                break
            end
            examined=examined+1
            if examined>=TRIGGER_BATCH then
                state.discovery_index=(index+1)%count
                break
            end
        end
    end
    if not chosen then return nil end
    chosen.entry=charge_entry(chosen)
    if chosen.entry then return chosen end
end

local failure_logged = false
local resolved = nil

local function clear_hold(reason)
    state.armed=false;resolved=nil;state.previous=nil
    state.next_discovery=nil;state.discovery_index=0
    state.suspended_since=nil;state.held_time=nil
    state.progress_time=nil;state.drove_since=nil;state.drove_peak=0
    state.shots={};state.last_shot=nil;state.reason=reason
end

local function suspend_hold(now,reason)
    state.suspended_since=state.suspended_since or now
    state.previous=nil
    state.reason=reason
    if now-state.suspended_since>=RECOVERY_WINDOW then clear_hold(reason..'; hold expired') end
end

local function step(dt)
    state.reason=nil -- diagnostics must describe this frame, not a past failure
    if not bind() then
        if not state.bind_logged then
            state.bind_logged = true
            note('Engine bindings unavailable; the addon stays idle: '
                 .. tostring(state.bind_error))
        end
        return
    end
    if not supported_build() then
        if not failure_logged then
            failure_logged = true
            note('Unsupported game build; the addon is disabled.')
        end
        return
    end
    local now = seconds()
    maintain_charge_record(now)
    local down,avatar,held = local_fire()
    if down==nil then
        -- Unknown input is not proof of release. Retain only a short-lived
        -- binding, with no charge writes until all validation succeeds again.
        suspend_hold(now,'native Fire input unavailable')
        return
    end
    if not down then
        if state.armed and rawget(_G, 'ArcThrowerDiagnostics') then
            local intervals = {}
            for index = 2, #state.shots do
                local interval = state.shots[index]
                if interval then intervals[#intervals + 1] = interval end
            end
            local summary = 'released after ' .. tostring(#state.shots) .. ' shot(s)'
            if #intervals > 0 then
                local total, minimum, maximum = 0, intervals[1], intervals[1]
                for _, interval in ipairs(intervals) do
                    total = total + interval
                    minimum = math.min(minimum, interval)
                    maximum = math.max(maximum, interval)
                end
                summary = summary .. string.format(
                    '; interval min %.3f mean %.3f max %.3f (%d)',
                    minimum, total / #intervals, maximum, #intervals)
            end
            log_line(summary)
        end
        clear_hold(nil)
        return
    end

    if state.suspended_since and (now-state.suspended_since>=RECOVERY_WINDOW
        or (state.held_time and held<state.held_time)) then
        clear_hold('interrupted hold requires a new fire command')
    end
    if resolved then
        local identity = read(resolved.entity, 24)
        if not identity then suspend_hold(now,'weapon identity unreadable');return end
        if identity ~= resolved.identity or avatar ~= resolved.avatar then
            clear_hold('weapon entity changed')
            return
        end
        local owned=local_weapon(identity,avatar)
        if owned==nil then suspend_hold(now,'weapon holder unavailable');return end
        if not owned then
            clear_hold('weapon holder changed')
            return
        end
        local entry=charge_entry(resolved)
        if entry==nil then suspend_hold(now,'charge binding unavailable');return end
        if entry==false then
            clear_hold('charge binding changed')
            return
        end
        if entry~=resolved.entry then
            resolved.entry=entry;state.previous=nil;state.drove_since=nil;state.drove_peak=0
        end
    end

    -- Only assist after the engine issued a fire command for an arc thrower, so
    -- holding the button for another weapon stays untouched.
    if not state.armed then
        if now < (state.next_discovery or 0) then return end
        state.next_discovery = now + 0.1
        local chosen,reason = active_arc(avatar)
        if not chosen then
            state.reason = reason or 'waiting for the engine fire command'
            return
        end
        resolved = chosen
        resolved.avatar = avatar
        state.armed = true
        state.shots = {}
        state.last_shot = nil
        state.reason = nil
        state.drove_since = nil
        state.drove_peak = 0
        state.progress_time=now
        log_line(string.format('assist armed entity=%#x entry=%#x',
                               chosen.entity, chosen.entry))
    end

    state.suspended_since=nil;state.held_time=held

    local blob = read(resolved.entry, ENTRY_SIZE)
    if not blob then
        state.reason = 'charge entry unreadable'
        return
    end
    local value = f32(blob, 4)
    local full = f32(blob, 8)
    local flag = blob:byte(13)
    if full~=full or value~=value or full <= 0.1 or value<0 then
        state.reason = 'invalid full-charge time'
        return
    end

    -- Recheck a stalled cycle for a replacement weapon. The engine's original
    -- one-shot fire command may already be cleared: that alone must not cancel
    -- a still-held, identity- and slot-validated Arc during a reload or pause.
    if not state.drove_since then
        state.drove_since = now
        state.drove_peak = value
    end
    state.drove_peak = math.max(state.drove_peak or 0, value)
    if (now - state.drove_since) > 1.2 and state.drove_peak < full * 0.25 then
        state.rescans = state.rescans + 1
        log_line(string.format(
            'entry %#x stalled (peak %.3f) - checking the current binding (#%d)',
            resolved.entry, state.drove_peak, state.rescans))
        local chosen=active_arc(avatar)
        state.drove_since=now;state.drove_peak=value
        if chosen and (chosen.entity~=resolved.entity or chosen.identity~=resolved.identity or chosen.entry~=resolved.entry) then
            chosen.avatar=avatar;resolved=chosen;state.previous=nil
            return
        end
    end

    local previous = state.previous
    state.previous = value
    -- A missing auto-fire patch can also leave charge stuck at full, which the
    -- low-charge stall check above cannot detect. Search for another matching
    -- data record only after sustained lack of progress, within the scan budget.
    if not previous or math.abs(value-previous)>1e-4 then state.progress_time=now end
    if now-(state.progress_time or now)>math.max(1.2,full*1.5) then
        state.rescan_requested=true;state.progress_time=now
    end
    -- Progress belongs to this charge cycle, not the best charge since press.
    -- Otherwise a completed first shot disables stall recovery for the hold.
    if previous and value < previous - 0.01 then
        state.drove_since=now;state.drove_peak=value
    end
    if rawget(_G, 'ArcThrowerDiagnostics') and previous and previous > full * 0.5 and value < full * 0.05 then
        local interval = state.last_shot and (now - state.last_shot) or nil
        state.last_shot = now
        state.shots[#state.shots + 1] = interval or false
        log_line(string.format('shot %d (charge %.3f -> %.3f, interval %s)',
                               #state.shots, previous, value,
                               interval and string.format('%.3f', interval) or 'n/a'))
    end

    -- The engine's charge updater advances the charge by the frame delta while
    -- the charging flag is set and fires when it crosses the full-charge time,
    -- so keeping that flag asserted is the whole job.
    if not write(resolved.entry + 12, '\x01') then
        state.reason = 'charge flag write failed'
        return
    end

    if rawget(_G, 'ArcThrowerDiagnostics') and ((not state.status) or (now - state.status >= 0.25)) then
        local window = now - (state.status or now)
        local delta = value - (state.status_charge or value)
        state.status = now
        state.status_charge = value
        log_line(string.format(
            'hold entry=%#x charge=%.3f full=%.3f flag=%d rate=%.2f/s',
            resolved.entry, value, full, flag, window > 0 and delta / window or 0))
    end
end

local previous_update = rawget(_G, 'update')
local function assist(dt)
    if type(dt) ~= 'number' then dt = 0 end
    local ok, reason = pcall(step, dt)
    if not ok then
        state.errors = state.errors + 1
        if state.errors == 1 then
            note('error #' .. tostring(state.errors) .. ': ' .. tostring(reason))
        end
    elseif state.reason then
        local now = seconds()
        if state.reason_log ~= state.reason or (now - (state.reason_time or 0) > 2) then
            state.reason_log = state.reason
            state.reason_time = now
            log_line('idle: ' .. state.reason)
        end
    else
        state.reason_log = nil
    end
end

local function wrapped_update(dt, ...)
    assist(dt)
    if type(previous_update) == 'function' then
        return previous_update(dt, ...)
    end
end

update = wrapped_update

-- Update owns the assist. Render remains untouched so discovery and native
-- writes run once per game update, regardless of how often the engine renders.

note('Arc Thrower Revamped ' .. module.revision .. ' initialised (loader API ' ..
     tostring(loader and loader.api or '?') .. ')')
