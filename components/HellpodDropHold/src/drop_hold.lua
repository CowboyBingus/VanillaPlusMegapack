-- Holds the local player's own drop pod while the player cannot see the world, and
-- lets it fall once they can. Mechanics (game.dll RVAs of Steam build 25480438;
-- docs/TECHNICAL.md has the evidence):
-- - A loading period starts while the game state ([game+0x3326340] + 0xAC21C) is
--   5 or 6 (preparing the ship or a mission: the loading screen), or while a
--   loading presenter is open in the UI's PresenterManager ([game+0x347CE28] +
--   0x4288: HUD, menu and popup presenter at +8, +12, +16, the menu stack's five
--   ids at +20 and its depth at +40; menu presenter 2 is LoadingMission, 4
--   LoadingTutorial).
-- - It lasts, in a mission, while a join is still finishing (is_hotjoining,
--   [game+0x347CEF0] + 92135) or a cutscene plays ([game+0x346D530] + 6412: the
--   current scene, then the queued one). A joining player's game queues
--   ship_teleporter_network_join (15) on the ship; it clears is_hotjoining and
--   interrupts that cutscene only when its synchronized tasks are done in the
--   mission state, while the host has already spawned that player's drop: the pod
--   falls unseen. In a live join on 2026-10-05 (v1.0) state 6 ended before the pod
--   existed, and the pod had landed before the player could see it.
-- - The HellpodComponent manager is [game+0x3326D58]. Each active pod has an
--   entity record (64-bit type hash, entity id, unit, network id, flags with
--   bit 0 = owned by this machine), a 160-byte local state and a 20-byte
--   networked state (phase: 0 falling, 1 braking, 2 landed; then position).
-- - The machine that owns a pod moves it down by
--   ((1 - t) * braking_velocity + t * initial_velocity) * dt every frame and
--   publishes the result. t is the float at local state +32: 1 at spawn, and it
--   only decays toward 0 while braking, and only while above 0.
-- - A player's own machine creates and owns that player's drop pod, also when
--   joining a mission in progress. Holding is one write of t on that machine:
--   t_hold makes the step 0.5 m/s * dt. Releasing writes the saved t back.
local ffi = require('ffi')

local hold = {
    game_rva = 0x3326340, state_offset = 0xAC21C,
    ui_state_rva = 0x347CE28, presenters_offset = 0x4290, stack_offset = 0x429C, max_depth = 5,
    -- The cutscene manager (current scene id, then the queued one) and, for the log,
    -- the session object's client state and hotjoin flags (is_hotjoining, has_hotjoined).
    cutscene_rva = 0x346D530, scene_offset = 6412,
    session_rva = 0x347CEF0, client_state_offset = 91288, hotjoin_offset = 92135,
    manager_rva = 0x3326D58, header_offset = 36, header_size = 84, max_capacity = 4096,
    settings_rva = 0x346BF98, settings_table_offset = 15805152, settings_slots = 16,
    settings_records = 256, settings_size = 104, settings_count = 64,
    record_size = 24, local_size = 160, net_size = 20, factor_offset = 32,
    -- Seconds: the idle and pod-check poll interval, and the longest hold.
    poll = 0.25, cap = 120,
    -- The held pod still sinks this fast (m/s): a zero step would give the
    -- game's look rotation and landing ray a zero direction.
    hold_speed = 0.5, scan_chunk = 256,
    -- Seconds the event log keeps following the game state and presenters after
    -- a loading screen or a hold ends.
    watch = 30,
}
-- Game states behind a loading screen: 5 preparing the ship, 6 preparing a mission.
local PREPARING = {[5] = true, [6] = true}
-- Menu presenters that are loading screens: LoadingMission and LoadingTutorial.
local LOADING = {[2] = true, [4] = true}
-- Names for the event log (game.dll's presenter name tables 0x21DD450 and 0x21DC810).
local HUD_NAMES = {[0] = 'none', 'intro', 'ship', 'mission', 'tutorial'}
local MENU_NAMES = {[0] = 'none', 'main', 'loading mission', 'loading ship', 'loading tutorial', 'armory',
    [13] = 'mission end', [14] = 'loadout', [15] = 'hologram', [23] = 'mission summary', [24] = 'load', [25] = 'join'}
-- Cutscene names (game.dll 0x117E950).
local SCENE_NAMES = {[0] = 'none', 'mission extraction', 'ship bridge hellpod launch', 'ship bridge intro',
    'ship clan station reveal', 'ship cryogenic intro', 'ship hellpod launch', 'ship intro',
    'ship mission return failure', 'ship mission return success', 'ship name resource loading', 'ship planet arrival',
    'ship planet departure', 'ship teleporter arrival', 'ship teleporter deeplink join', 'ship teleporter network join',
    'tutorial avatar respawn', 'tutorial cape ceremony', 'tutorial intro', 'tutorial outro', 'tutorial outro to ship'}
-- Game states in which a playing cutscene keeps a loading period going: the mission and its preparation.
local SCENE_STATES = {[4] = true, [6] = true}
-- The player drop pod types: entity hash halves and HellpodComponent variant.
local TYPES = {
    {low = 0x1928D3E2, high = 0xE58163E7, variant = 2, name = 'initial spawn'},  -- 0xE58163E71928D3E2
    {low = 0xA9D6D849, high = 0xEF9EB729, variant = 1, name = 'reinforce'},      -- 0xEF9EB729A9D6D849
}
hold.types = TYPES
local HIGH, LOWEST, USER_END = 4294967296, 0x10000, 0x800000000000

-- Every read lands in one of these buffers, made once and addressed by number,
-- and is decoded in place: a check allocates nothing.
local function buffer(ctype, count)
    local data = ffi.new(ctype, count)
    return data, tonumber(ffi.cast('uintptr_t', data))
end
local words, words_at = buffer('uint32_t[?]', 21)       -- a pointer (0-1) or the 84-byte manager header
local state, state_at = buffer('uint32_t[?]', 1)        -- the game state
local signals, signals_at = buffer('uint32_t[?]', 9)    -- HUD, menu, popup presenter, five stack ids, depth
local scenes, scenes_at = buffer('uint32_t[?]', 2)      -- current and queued cutscene
local client, client_at = buffer('uint32_t[?]', 1)      -- the client state, for the log
local joining, joining_at = buffer('uint8_t[?]', 2)     -- is_hotjoining, has_hotjoined, for the log
local record, record_at = buffer('uint32_t[?]', 6)      -- hash low, high, id, unit, network id, flags
local phase, phase_at = buffer('uint32_t[?]', 1)
local factor, factor_at = buffer('float[?]', 1)
local height, height_at = buffer('float[?]', 1)
local variant, variant_at = buffer('uint32_t[?]', 1)
local speeds, speeds_at = buffer('float[?]', 4)         -- initial velocity, braking height, braking velocity, time
local slots, slots_at = buffer('uint32_t[?]', 64)       -- 16 settings slots: hash low, high, index, padding
local pointers, pointers_at = buffer('uint32_t[?]', 512) -- up to 256 entity record pointers
local cell = ffi.new('float[1]')

local function valid_pointer(value)
    if value < LOWEST or value >= USER_END then return nil end
    return value
end
local function is_power_of_two(value)
    while value > 1 and value % 2 == 0 do value = value / 2 end
    return value == 1
end
-- The user-mode pointer stored at address, as a number, or nil.
local function pointer_at(api, address)
    if not api.read_to(address, 8, words_at) then return nil end
    return valid_pointer(words[0] + words[1] * HIGH)
end
-- A float as the game stores it: its 4 bytes and the rounded value.
local function float_bytes(value)
    cell[0] = value
    return ffi.string(cell, 4), cell[0]
end

-- Reads the game state and the presenters into state and signals: true while the
-- player cannot see the world (a preparing state, or a loading presenter open or
-- anywhere on the menu stack), false when they can, nil when either cannot be read
-- or makes no sense.
local function loading_screen(api, game)
    local object = pointer_at(api, game + hold.game_rva)
    if not object or not api.read_to(object + hold.state_offset, 4, state_at) then return nil end
    local ui = pointer_at(api, game + hold.ui_state_rva)
    if not ui or not api.read_to(ui + hold.presenters_offset, 36, signals_at) then return nil end
    local depth = signals[8]
    if depth > hold.max_depth then return nil end
    if PREPARING[state[0]] or LOADING[signals[1]] then return true end
    for index = 0, depth - 1 do
        if LOADING[signals[3 + index]] then return true end
    end
    return false
end

-- Reads the join flags and the cutscene manager (after loading_screen, which read the
-- state): true while, in the mission or its preparation, a join is still finishing
-- (is_hotjoining) or a cutscene plays or waits; false when not; nil when neither can be
-- read. Both end in the client's synchronized-tasks-done (0xAD4520), which clears
-- is_hotjoining and interrupts the cutscene. Unreadable values show as 255 or 9999 in
-- the log and never count.
local function still_covered(api, game)
    local session_object = pointer_at(api, game + hold.session_rva)
    local flags_read = session_object and api.read_to(session_object + hold.client_state_offset, 4, client_at)
        and api.read_to(session_object + hold.hotjoin_offset, 2, joining_at)
    if not flags_read then client[0], joining[0], joining[1] = 255, 255, 255 end
    local manager = pointer_at(api, game + hold.cutscene_rva)
    local scenes_read = manager and api.read_to(manager + hold.scene_offset, 8, scenes_at)
    if not scenes_read then scenes[0], scenes[1] = 9999, 9999 end
    if not (flags_read or scenes_read) then return nil end
    local scene = scenes_read and (scenes[0] ~= 0 or scenes[1] ~= 0)
    local joining_now = flags_read and joining[0] == 1
    return SCENE_STATES[state[0]] == true and (scene or joining_now) or false
end

-- The state and presenters just read (and the cutscene and join flags when read), in
-- words, for the event log.
local function describe_signals(extended)
    local ids = {}
    for index = 0, math.min(signals[8], hold.max_depth) - 1 do
        local id = signals[3 + index]
        ids[#ids + 1] = MENU_NAMES[id] or tostring(id)
    end
    local text = string.format('game state %d, hud %s, menu %s, popup %d, menu stack [%s]', state[0],
        HUD_NAMES[signals[0]] or tostring(signals[0]), MENU_NAMES[signals[1]] or tostring(signals[1]), signals[2],
        table.concat(ids, ', '))
    if not extended then return text end
    return text .. string.format(', cutscene %s (next %s), client state %d, hotjoining %d, hotjoined %d',
        SCENE_NAMES[scenes[0]] or tostring(scenes[0]), SCENE_NAMES[scenes[1]] or tostring(scenes[1]), client[0],
        joining[0], joining[1])
end

-- Whether the state, a presenter (or, when read, the cutscene or a join flag) changed
-- since the last call; keeps the last values in session.seen (numbers, so a
-- comparison allocates nothing).
local function signals_changed(session, extended)
    local seen = session.seen
    local changed = seen[0] ~= state[0]
    seen[0] = state[0]
    for index = 0, 8 do
        if seen[index + 1] ~= signals[index] then
            changed, seen[index + 1] = true, signals[index]
        end
    end
    if not extended then return changed end
    local values = seen.extended
    if values[1] ~= scenes[0] or values[2] ~= scenes[1] or values[3] ~= client[0] or values[4] ~= joining[0]
        or values[5] ~= joining[1] then
        changed = true
        values[1], values[2], values[3], values[4], values[5] = scenes[0], scenes[1], client[0], joining[0], joining[1]
    end
    return changed
end

-- The manager's active count and array addresses, in one reused table; nil and
-- 'no_manager' before the manager exists, nil and 'manager_layout' when its
-- header makes no sense.
local view = {}
local function read_manager(api, game)
    local manager = pointer_at(api, game + hold.manager_rva)
    if not manager then return nil, 'no_manager' end
    if not api.read_to(manager + hold.header_offset, hold.header_size, words_at) then return nil, 'manager_layout' end
    -- words[i] holds manager + 36 + 4 * i.
    local capacity, total, active = words[0], words[2], words[3]
    if capacity > hold.max_capacity or total > capacity or active > total then return nil, 'manager_layout' end
    view.manager, view.active = manager, active
    view.records = valid_pointer(words[13] + words[14] * HIGH)
    view.locals = valid_pointer(words[17] + words[18] * HIGH)
    view.nets = valid_pointer(words[19] + words[20] * HIGH)
    -- The entity-id map (+64 slots, +72 capacity, a power of two, +76 empty key, +80 multiplier).
    view.map, view.map_capacity = valid_pointer(words[7] + words[8] * HIGH), words[9]
    view.map_empty, view.map_multiplier = words[10], words[11]
    if active > 0 and not (view.records and view.locals and view.nets and view.map and view.map_capacity > 0
        and view.map_capacity <= 65536 and view.map_capacity % 1 == 0 and is_power_of_two(view.map_capacity)) then
        return nil, 'manager_layout'
    end
    return view
end

-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles: a is split into 16-bit halves.
local function mul32(a, b)
    local a_low, a_high = a % 65536, math.floor(a / 65536)
    return (a_low * b + (a_high * (b % 65536)) % 65536 * 65536) % HIGH
end

-- The index the manager's own entity-id map gives for id, or nil. The game probes
-- slot (probe + id * multiplier) & (capacity - 1) until the key or the empty key.
local map_slot, map_slot_at = buffer('uint32_t[?]', 2)
local function map_index(api, v, id)
    local start = mul32(id, v.map_multiplier)
    for probe = 0, math.min(v.map_capacity, 64) - 1 do
        local slot = (start + probe) % v.map_capacity
        if not api.read_to(v.map + slot * 8, 8, map_slot_at) then return nil end
        if map_slot[0] == v.map_empty then return nil end
        if map_slot[0] == id then return map_slot[1] end
    end
    return nil
end

-- Reads the entity record at address into record; the pod type when it is a
-- player drop pod this machine owns, else nil.
local function own_drop_pod(api, address)
    if not address or not api.read_to(address, hold.record_size, record_at) then return nil end
    if record[5] % 2 ~= 1 then return nil end
    for _, kind in ipairs(TYPES) do
        if record[0] == kind.low and record[1] == kind.high then return kind end
    end
    return nil
end

local function phase_of(api, v, index)
    if not api.read_to(v.nets + index * hold.net_size, 4, phase_at) then return nil end
    return phase[0]
end

-- One reused result: the pod's index, entity id, record address and type.
local found = {}
local function candidate(api, v, index, address, skip)
    local kind = own_drop_pod(api, address)
    if not kind or skip[record[2]] then return nil end
    local id = record[2]
    local current = phase_of(api, v, index)
    if current ~= 0 and current ~= 1 then return nil end
    -- The manager's own map must agree: this entity id lives at this index.
    if map_index(api, v, id) ~= index then return nil end
    found.index, found.id, found.record, found.kind = index, id, address, kind
    return found
end

-- The first of this machine's own drop pods that is still falling or braking and
-- not in skip (entity ids handled already), or nil. Reads the record pointers in
-- chunks of up to 256.
local function find_pod(api, v, skip)
    local first = 0
    while first < v.active do
        local count = math.min(v.active - first, hold.scan_chunk)
        if not api.read_to(v.records + first * 8, count * 8, pointers_at) then return nil end
        for slot = 0, count - 1 do
            local address = valid_pointer(pointers[slot * 2] + pointers[slot * 2 + 1] * HIGH)
            local pod = candidate(api, v, first + slot, address, skip)
            if pod then return pod end
        end
        first = first + count
    end
    return nil
end

-- The pod at held.index still has the same record, entity id, type and owner.
-- The manager compacts its arrays when a pod goes, so an index can change.
local function same_pod(api, v, held, index)
    if index >= v.active or not api.read_to(v.records + index * 8, 8, words_at) then return false end
    if words[0] + words[1] * HIGH ~= held.record then return false end
    return own_drop_pod(api, held.record) == held.kind and record[2] == held.id and map_index(api, v, held.id) == index
end

-- The held pod's current index; nil and 'gone' when the manager no longer has
-- it; nil and 'unknown' when the manager could not be read, so the hold must be
-- kept and checked again.
local function locate(api, v, held)
    if same_pod(api, v, held, held.index) then return held.index end
    local first = 0
    while first < v.active do
        local count = math.min(v.active - first, hold.scan_chunk)
        if not api.read_to(v.records + first * 8, count * 8, pointers_at) then return nil, 'unknown' end
        for slot = 0, count - 1 do
            if pointers[slot * 2] + pointers[slot * 2 + 1] * HIGH == held.record
                and same_pod(api, v, held, first + slot) then
                return first + slot
            end
        end
        first = first + count
    end
    return nil, 'gone'
end

-- The manager view and the held pod's index, as locate; 'unknown' when the
-- manager cannot be read.
local function find_held(api, game, held)
    local v, problem = read_manager(api, game)
    if not v then return nil, nil, problem == 'no_manager' and 'gone' or 'unknown' end
    local index, why = locate(api, v, held)
    return v, index, why
end

local function settings_record(api, table_address, index, kind)
    if index >= hold.settings_count then return nil end
    local address = table_address + hold.settings_records + index * hold.settings_size
    if not api.read_to(address, 4, variant_at) or not api.read_to(address + 20, 16, speeds_at) then return nil end
    local initial, braking, target_time = speeds[0], speeds[2], speeds[3]
    if variant[0] ~= kind.variant or not (target_time > 0) then return nil end
    if not (braking > hold.hold_speed and initial > braking and initial <= 5000) then return nil end
    return initial, braking
end

-- The pod type's initial and braking velocity from its HellpodComponent settings
-- (16 open-addressed slots from the hash's low 4 bits, then 104-byte records at
-- +256); nil when the table or the record make no sense.
local function velocities(api, game, kind)
    local owner = pointer_at(api, game + hold.settings_rva)
    local table_address = owner and pointer_at(api, owner + hold.settings_table_offset)
    if not table_address or not api.read_to(table_address, hold.settings_slots * 16, slots_at) then return nil end
    local slot = kind.low % hold.settings_slots
    for _ = 1, hold.settings_slots do
        local low, high = slots[slot * 4], slots[slot * 4 + 1]
        if low == kind.low and high == kind.high then
            return settings_record(api, table_address, slots[slot * 4 + 2], kind)
        end
        if low == 0 and high == 0 then return nil end
        slot = (slot + 1) % hold.settings_slots
    end
    return nil
end

-- The pod's height (networked position z) for the event log, or -1.
local function height_of(api, v, index)
    if not api.read_to(v.nets + index * hold.net_size + 12, 4, height_at) then return -1 end
    return height[0]
end

local function factor_address(v, index)
    return v.locals + index * hold.local_size + hold.factor_offset
end

-- Writes value's 4 bytes at address and reads them back: one page check, right
-- before the store.
local function store(api, address, bytes, value)
    if not api.write_batch(address, 4, {{0, bytes}}) then return false end
    return api.read_to(address, 4, factor_at) and factor[0] == value
end

local function note(session, text)
    if session.note then session.note(text) end
end

-- Holds the found pod: true, or false and why the mod must stop, or nil and why
-- this pod is left alone.
local function start_hold(api, game, session, v, pod)
    local initial, braking = velocities(api, game, pod.kind)
    if not initial then return false, 'drop_pod_settings_unrecognized' end
    local address = factor_address(v, pod.index)
    if not api.read_to(address, 4, factor_at) then return false, 'drop_pod_unreadable' end
    local saved = factor[0]
    -- Anything outside the game's own 0..1 was written by someone else.
    if not (saved >= 0 and saved <= 1) then
        session.done[pod.id] = true
        return nil, 'drop_pod_speed_set_elsewhere'
    end
    local bytes, value = float_bytes((hold.hold_speed - braking) / (initial - braking))
    local held = {id = pod.id, record = pod.record, kind = pod.kind, index = pod.index, saved = saved,
                  value = value, held_for = 0}
    if not same_pod(api, v, held, pod.index) then return nil, 'drop_pod_moved' end
    if not store(api, address, bytes, value) then return false, 'drop_pod_not_writable' end
    session.held = held
    note(session, string.format('holding %s pod %d at %.0f m (speed factor %.3f -> %.3f)', pod.kind.name,
        pod.id, height_of(api, v, pod.index), saved, value))
    return true
end

-- Puts the saved factor back on the held pod, only over this mod's own value.
-- Returns true, or false and why (a failed write). The hold is forgotten unless
-- the manager could not be read: then it is kept and released at a later poll.
local function release(api, game, session, reason)
    local held = session.held
    if not held then return true end
    local v, index, why = find_held(api, game, held)
    if why == 'unknown' then
        held.retry = reason
        return true
    end
    session.held, session.done[held.id] = nil, true
    if not index then
        note(session, 'released pod ' .. held.id .. ' (' .. reason .. '): the pod is gone')
        return true
    end
    local address = factor_address(v, index)
    if not api.read_to(address, 4, factor_at) or factor[0] ~= held.value then
        note(session, 'released pod ' .. held.id .. ' (' .. reason .. '): left unchanged, its speed changed elsewhere')
        return true
    end
    local bytes, value = float_bytes(held.saved)
    if not store(api, address, bytes, value) then return false, 'drop_pod_release_failed' end
    note(session, string.format('released pod %d (%s) after %.1f s at %.0f m', held.id, reason, held.held_for,
        height_of(api, v, index)))
    return true
end
hold.release = release

-- Whether the player cannot see the world. A forced session (test builds only)
-- treats every moment as loading.
-- loading_screen, plus an event when the state or a presenter changed while the log
-- follows them (session.watch seconds after a loading screen or a hold).
-- Notes every own drop pod the first time it is seen during a loading period or the
-- watch after it: when it appeared, against the signals, is the timing evidence.
local function sight_pods(api, v, session)
    local first = 0
    while first < v.active do
        local count = math.min(v.active - first, hold.scan_chunk)
        if not api.read_to(v.records + first * 8, count * 8, pointers_at) then return end
        for slot = 0, count - 1 do
            local kind = own_drop_pod(api, valid_pointer(pointers[slot * 2] + pointers[slot * 2 + 1] * HIGH))
            local id = kind and record[2]
            if id and not session.sighted[id] then
                session.sighted[id] = true
                note(session, string.format('own %s pod %d seen at %.0f m, phase %s', kind.name, id,
                    height_of(api, v, first + slot), tostring(phase_of(api, v, first + slot))))
            end
        end
        first = first + count
    end
end

-- One check of the signals: loading (true while a loading screen is up, false when
-- not, nil when unreadable) and, when extended, scene (true while a cutscene plays in
-- the mission or its preparation). Notes a change while the log follows the signals.
local function observe(api, game, session, extended)
    local up = loading_screen(api, game)
    if up == nil then return nil, false end
    local scene = extended and still_covered(api, game) or false
    if session.watch > 0 and signals_changed(session, extended) then note(session, describe_signals(extended)) end
    return up, scene
end

-- Whether a loading period goes on: a loading screen, or a cutscene in the mission
-- after one. A forced session (test builds only) treats every moment as loading.
local function screen_up(api, game, session)
    local up, scene = observe(api, game, session, true)
    if session.force then return true end
    if up == nil then return nil end
    return up or scene
end

-- Polls 4 times a second. Only a loading screen starts a loading period; a cutscene
-- alone never does. For hold.watch seconds after one, the log keeps following the
-- signals and the own pods.
local function idle(api, game, session, dt)
    local watching = session.watch > 0
    if watching then session.watch = session.watch - dt end
    session.since_poll = session.since_poll + dt
    if session.since_poll < hold.poll then return true end
    session.since_poll = 0
    local up = observe(api, game, session, watching)
    if watching then
        local v = read_manager(api, game)
        if v then sight_pods(api, v, session) end
    end
    if not (up or session.force) then return true end
    session.loading, session.last_active, session.scan_wait = true, -1, 0
    if not session.force then
        session.done, session.sighted = {}, {}
        note(session, 'loading screen up')
    end
    return nil
end

-- While a loading period lasts: every frame, a new own pod is held at once.
-- The pods are scanned when the active count changed, and every 0.25 s.
local function loading(api, game, session, dt)
    session.watch = hold.watch
    local up = screen_up(api, game, session)
    if up == nil then return true end
    if not up then
        session.loading, session.since_poll = false, 0
        note(session, 'loading screen gone')
        return true
    end
    local v, problem = read_manager(api, game)
    if not v then return problem ~= 'manager_layout', problem end
    session.scan_wait = session.scan_wait - dt
    if v.active == session.last_active and session.scan_wait > 0 then return true end
    session.last_active, session.scan_wait = v.active, hold.poll
    sight_pods(api, v, session)
    local pod = find_pod(api, v, session.done)
    if not pod then return true end
    local ok, why = start_hold(api, game, session, v, pod)
    if ok == nil then note(session, 'pod ' .. pod.id .. ' left alone: ' .. why) end
    return ok ~= false, why
end

-- 'present', 'gone' or 'unknown', checked at each holding poll.
local function held_state(api, game, held)
    local _, index, why = find_held(api, game, held)
    if index then
        held.index = index
        return 'present'
    end
    return why
end

-- The reason to release now, other than the end of the cover, if any.
local function due(session, held)
    if held.retry then return held.retry end
    if session.force and held.held_for >= session.force then return 'test hold ended' end
    if held.held_for >= hold.cap then return 'longest hold' end
    return nil
end

-- While holding: every frame, the cover is checked, and its end releases the pod in
-- that frame, so the player sees it already falling (v1.1 waited 1.5 s after the
-- end, and the pod looked stuck in the air). 4 times a second, the pod is checked to
-- still be there.
local function holding(api, game, session, dt)
    local held = session.held
    held.held_for = held.held_for + dt
    session.since_poll = session.since_poll + dt
    local reason = due(session, held)
    -- A retry waits for the next poll, so an unreadable manager costs reads only
    -- 4 times a second.
    if reason and (not held.retry or session.since_poll >= hold.poll) then
        session.since_poll = 0
        return release(api, game, session, reason)
    end
    session.watch = hold.watch
    local up, scene = observe(api, game, session, true)
    if up == false and not scene and not session.force and not held.retry then
        session.loading = false
        note(session, 'loading screen and cutscene gone')
        return release(api, game, session, 'loading screen gone')
    end
    if session.since_poll < hold.poll then return true end
    session.since_poll = 0
    if held_state(api, game, held) == 'gone' then
        session.held, session.done[held.id] = nil, true
        note(session, 'pod ' .. held.id .. ' is gone')
    end
    return true
end

-- A fresh session: polls at once.
function hold.session(force)
    return {since_poll = hold.poll, loading = false, last_active = -1, scan_wait = 0, done = {}, sighted = {},
            force = force, watch = 0, seen = {extended = {}}}
end

-- One frame. Returns true, or false and why the mod must stop.
function hold.update(api, game, session, dt)
    if not (type(dt) == 'number' and dt > 0 and dt < 10) then dt = 0 end
    if session.held then return holding(api, game, session, dt) end
    if session.loading then return loading(api, game, session, dt) end
    if idle(api, game, session, dt) then return true end
    return loading(api, game, session, 0)
end

hold.loading_screen = loading_screen
-- These functions run 4 times a second, or every frame only while a loading
-- screen is up, and stay interpreted: compiled, they would add machine code to
-- the game's shared code cache for no gain. Interpreted, a check still
-- allocates nothing.
local functions = {valid_pointer = valid_pointer, is_power_of_two = is_power_of_two, mul32 = mul32,
    still_covered = still_covered, sight_pods = sight_pods,
    map_index = map_index, pointer_at = pointer_at, float_bytes = float_bytes,
    loading_screen = loading_screen, describe_signals = describe_signals, signals_changed = signals_changed,
    read_manager = read_manager, own_drop_pod = own_drop_pod, phase_of = phase_of,
    candidate = candidate, find_pod = find_pod, same_pod = same_pod, locate = locate, find_held = find_held,
    settings_record = settings_record, velocities = velocities, height_of = height_of,
    factor_address = factor_address, store = store, note = note, start_hold = start_hold, release = release,
    observe = observe, screen_up = screen_up, idle = idle, loading = loading, held_state = held_state, due = due,
    holding = holding, session = hold.session, update = hold.update}
-- A name bound to nothing would drop out of the table above: count them.
local listed = 0
for name, check in pairs(functions) do
    assert(type(check) == 'function', name)
    if jit and jit.off then jit.off(check) end
    listed = listed + 1
end
assert(listed == 36, 'drop_hold.lua: a function is missing from the interpreted list')
return hold
