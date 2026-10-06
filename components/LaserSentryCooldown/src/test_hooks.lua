-- Laser Sentry Cooldown: hooks of the live test build only (scripts/build.py --test). Never in the release.
-- The test build behaves exactly like the release (no options, no other change) and adds a log, read-only:
--   - every SAMPLE_FRAMES frames it reads the WeaponHeat manager ([game+0x3326D48]: +20/+24/+28 instance
--     counts, +64 entity record pointers, +88 12-byte replicated state: spare heat sinks, temperature,
--     overheated, firing) and logs each Laser Sentry when it appears, when its temperature band (25 heat),
--     overheated, firing, heat sinks or turret state (its AI behavior state: 13 firing, 6 switched off after an
--     overheat, 7 powering up) change, and when it disappears, with the time since its last overheat;
--   - a RESULT line when an overheated Laser Sentry recovers (cooled and able to fire again) or disappears
--     while still overheated;
--   - every RECORD_CHECK_FRAMES frames, whether the heat record still holds the change, both ranges (a game that
--     rebuilt its weapon data mid-session would show up here).
-- Returns install(Cooldown, instance, runtime, memory).
local ffi = require('ffi')
local format = string.format

local SAMPLE_FRAMES = 6
local RECORD_CHECK_FRAMES = 300
local MAX_INSTANCES = 128 -- 8-byte pointers in one read of the adapter's 1 KB buffer

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64(bytes, offset)
    return u32(bytes, offset) + u32(bytes, offset + 4) * 4294967296
end

local f32_cell = ffi.new('float[1]')
local function f32(bytes, offset)
    ffi.copy(f32_cell, bytes:sub(offset + 1, offset + 4), 4)
    return tonumber(f32_cell[0])
end

local function hex(bytes)
    return bytes and (bytes:gsub('.', function(c) return format('%02x', c:byte()) end)) or 'unreadable'
end

return function(Cooldown, instance, runtime, memory)
    local api, note = instance.api, instance.note
    local game = memory.address(memory.module('game.dll'))
    local start = memory.time()
    local state = {frames = 0, counts = nil, sentries = {}, record_ok = nil}
    local function now() return memory.time() - start end
    local function log(line) note(format('[test %8.2f] %s', now(), line)) end

    -- The manager's header (96 bytes) with its instance counts logged when they change, or nil.
    local function manager_header()
        local manager = api.u64(game + Cooldown.HEAT_MANAGER_RVA)
        if not manager or manager < 0x10000 then return nil end
        local header = api.read(manager, 96)
        if not header then return nil end
        local counts = format('%d/%d/%d', u32(header, 20), u32(header, 24), u32(header, 28))
        if counts ~= state.counts then
            state.counts = counts
            log('heat instances total/active/owned ' .. counts)
        end
        return header
    end

    -- The entity id, owned bit and record address of the Laser Sentry whose record pointer is at slot index, or nil.
    local function laser_sentry(pointers, index)
        local entity = u64(pointers, 8 * index)
        local record = entity >= 0x10000 and api.read(entity, 24)
        if not record or u32(record, 0) ~= Cooldown.RESOURCE_LOW or u32(record, 4) ~= Cooldown.RESOURCE_HIGH then
            return nil
        end
        return u32(record, 8), record:byte(21) % 2, entity
    end

    -- The turret's AI state (behavior block +8: 13 firing, 6 switched off after an overheat, 7 powering up), or
    -- '?' when its behavior cannot be read (it runs on another machine, or the manager is not there).
    local function turret_state(id, entity)
        local block = Cooldown.behavior_block(api, game, id, entity)
        if not block or not api.view(block, 20) then return '?' end
        return tostring(api.words[2])
    end

    local function changed(current, previous)
        return current.bucket ~= previous.bucket or current.overheated ~= previous.overheated
            or current.firing ~= previous.firing or current.magazines ~= previous.magazines
            or current.turret ~= previous.turret
    end

    -- The RESULT line of a Laser Sentry whose overheated flag just fell: it cooled and can fire again.
    local function recovered(id, current)
        log(format('RESULT sentry %d recovered: overheated for %.1f s, temperature now %.1f; it can fire again',
                   id, now() - current.overheat_at, current.temperature))
    end

    -- Logs one Laser Sentry's replicated heat state (12 bytes) and turret state when it appears or changes.
    local function observe(id, owned, index, values, entity)
        local temperature = f32(values, 4)
        local current = {temperature = temperature, bucket = math.floor(temperature / 25), overheated = values:byte(9),
                         firing = values:byte(10), magazines = u32(values, 0), turret = turret_state(id, entity)}
        local previous = state.sentries[id]
        state.sentries[id] = current
        if not previous then
            current.since = now()
            log(format('sentry %d appeared at index %d (owned %d, heat sinks %d)', id, index, owned, current.magazines))
        else
            current.since, current.overheat_at = previous.since, previous.overheat_at
            if current.overheated == 1 and previous.overheated ~= 1 then current.overheat_at = now() end
            if current.overheated ~= 1 and previous.overheated == 1 and current.overheat_at then
                recovered(id, current)
            end
            if not changed(current, previous) then return end
        end
        local since = current.overheat_at and format(', %.2f s after overheat', now() - current.overheat_at) or ''
        log(format('sentry %d: temperature %.1f, overheated %d, firing %d, heat sinks %d, turret state %s%s', id,
                   temperature, current.overheated, current.firing, current.magazines, current.turret, since))
    end

    -- Logs and forgets every Laser Sentry this sample did not see.
    local function forget_missing(seen)
        for id, previous in pairs(state.sentries) do
            if not seen[id] then
                if previous.overheated == 1 then
                    log(format('RESULT sentry %d disappeared while overheated, %.2f s after the overheat',
                               id, now() - previous.overheat_at))
                end
                local since = previous.overheat_at and format('%.2f s after its last overheat', now() - previous.overheat_at)
                    or 'without an overheat'
                log(format('sentry %d disappeared %s (alive %.1f s, last temperature %.1f, overheated %d)',
                           id, since, now() - previous.since, previous.temperature, previous.overheated))
                state.sentries[id] = nil
            end
        end
    end

    -- One sample of every Laser Sentry instance in the WeaponHeat manager.
    local function sample()
        local header = manager_header()
        if not header then return end
        local count = math.min(math.max(u32(header, 20), u32(header, 24)), MAX_INSTANCES)
        local pointers = count > 0 and api.read(u64(header, 64), 8 * count)
        local seen = {}
        for index = 0, (pointers and count or 0) - 1 do
            local id, owned, entity = laser_sentry(pointers, index)
            local values = id and api.read(u64(header, 88) + 12 * index, 12)
            if values then
                seen[id] = true
                observe(id, owned, index, values, entity)
            end
        end
        forget_missing(seen)
    end

    -- The bytes of each edit's range in the record, joined, or nil when one is unreadable.
    local function ranges(edits)
        local parts = {}
        for index, edit in ipairs(edits) do
            parts[index] = api.read(instance.record + edit[1], #edit[2])
            if not parts[index] then return nil end
        end
        return table.concat(parts)
    end

    -- Does the record still hold what the addon wrote (or the vanilla bytes while it is not active)?
    local function check_record()
        if not instance.record then return end
        local edits = instance.patched and instance.edits or Cooldown.VANILLA_EDITS
        local current = ranges(edits)
        local expected = edits[1][2] .. edits[2][2]
        local ok = current == expected
        if ok ~= state.record_ok then
            state.record_ok = ok
            log(ok and format('record check: %s bytes in place', instance.patched and 'changed' or 'vanilla')
                or format('record check: UNEXPECTED bytes %s (expected %s)', hex(current), hex(expected)))
        end
    end

    local function step()
        state.frames = state.frames + 1
        if state.frames % SAMPLE_FRAMES == 0 then sample() end
        if state.frames % RECORD_CHECK_FRAMES == 0 then check_record() end
    end

    runtime.guard({name = 'LaserSentryCooldownTest', step = step, stop = function() end, log = log,
                   env = instance.env or _G}).install()
    log('test hooks installed: Laser Sentry heat log every ' .. SAMPLE_FRAMES .. ' frames, record check every '
        .. RECORD_CHECK_FRAMES .. ' frames')
end
