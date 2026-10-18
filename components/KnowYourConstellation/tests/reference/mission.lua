-- Reads the highlighted mission's inputs the way the game resolves them. Every
-- read lands in a buffer this reader keeps and its fields decode in place:
-- addresses are plain numbers, pointers decode from their bytes, and the
-- tables a refresh fills are reused, so neither the per-frame checks nor the
-- 0.5 s refresh allocate.
local ffi = require('ffi')
local bit = require('bit')
local M = {}

-- Expected transient states, while the game builds or switches screens, are
-- raised as constant tables {pending = reason, status = 'hidden: ' .. reason}:
-- a waiting frame builds no string, and the installer hides and retries on the
-- next frame without counting the frame toward stopping the mod (as v4.0 did
-- for every raised frame). Everything else raises a string and counts.
local function pending(reason) return {pending = reason, status = 'hidden: ' .. reason} end
local DATA_UNAVAILABLE = pending('Mission data unavailable')
local POINTER_UNAVAILABLE = pending('Mission pointer unavailable')
local NOT_READY = pending('Mission descriptor not ready')
local NO_MISSION = pending('No highlighted mission')
local NO_BRIEFING = pending('Briefing descriptor unavailable')
local NO_OWNER = pending('Briefing owner unavailable')
M.PENDING = {DATA_UNAVAILABLE, POINTER_UNAVAILABLE, NOT_READY, NO_MISSION, NO_BRIEFING, NO_OWNER}
-- An error's text for the unresolved list.
local function describe(why)
    if type(why) == 'table' and why.pending then return why.pending end
    return tostring(why)
end

local function u16(b, at) return b[at] + b[at + 1] * 256 end
local function u32(b, at) return b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216 end
-- The user-mode pointer stored at b[at] (little-endian), or nil.
local function pointer_at(b, at)
    if b[at + 6] ~= 0 or b[at + 7] ~= 0 then return nil end
    local value = u32(b, at) + (b[at + 4] + b[at + 5] * 256) * 4294967296
    if value < 0x10000 or value >= 0x800000000000 then return nil end
    return value
end
-- (a * b) mod 2^32 for 32-bit a and b, exact in doubles.
local function mul32(a, b)
    local low = a % 65536
    return (low * b + (a - low) / 65536 * b % 65536 * 65536) % 4294967296
end
local function clear(t)
    for key in pairs(t) do t[key] = nil end
end
-- A buffer reads land in: {data = uint8_t array, address = number, size}.
local function buffer(size)
    local data = ffi.new('uint8_t[?]', size)
    return {data = data, address = tonumber(ffi.cast('uintptr_t', data)), size = size}
end

-- Descriptor bytes that make up a mission's identity (seed, secondary seed,
-- faction, difficulty, planet, mission type).
local IDENTITY = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 26, 27}
local LAYOUTS = {[1] = {1097440, 1253440, 100}, [2] = {1253448, 1409448, 100}, [3] = {1409456, 1487456, 50}}
local CANDIDATES = {[2] = 276, [3] = 372, [4] = 468}
local FALLBACKS = {[2] = 564, [3] = 600, [4] = 636}
local CONFIG_MAPS = {73848, 49232}
-- The additional HordeOnly tag's marker in a mission record (+0x360).
local HORDE_MARKER = {73, 120, 130, 127, 209, 44, 124, 133}

-- Whether a and b hold the same NUL-terminated text at their start, compared
-- like matching '^([^%z]+)%z' on both: an empty or unterminated text never
-- matches.
local function text_length(b, size)
    for i = 0, size - 1 do
        if b[i] == 0 then return i > 0 and i or nil end
    end
    return nil
end
local function same_text(a, b, size)
    local n = text_length(a, size)
    if not n or text_length(b, size) ~= n then return false end
    for i = 0, n - 1 do
        if a[i] ~= b[i] then return false end
    end
    return true
end
local function same_bytes(a, b, size)
    for i = 0, size - 1 do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- A float decoder: the bits go in and the float comes out of one union cell.
-- Bytes stored through a second, differently typed view of a cell read back
-- stale in compiled code (LuaJIT's alias analysis treats the views as
-- independent). Declared on first use, under a private name.
local function float_decoder()
    if not pcall(ffi.typeof, 'hd2kyc_float_bits') then
        ffi.cdef('typedef union { uint32_t bits; float value; } hd2kyc_float_bits;')
    end
    local cell = ffi.new('hd2kyc_float_bits')
    return function(b, at)
        cell.bits = u32(b, at)
        return cell.value
    end
end

function M.new(api, game, resolve)
    local self = {api=api, game=game, resolve=resolve}
    local f32 = float_decoder()
    local scratch, bulk = buffer(128), buffer(53248)
    local descriptor_bytes, loaded_bytes, recheck_bytes = buffer(200), buffer(200), buffer(200)
    local advertised_bytes, packet_bytes = buffer(512), buffer(512)
    local settings_bytes, config_bytes, hash_bytes = buffer(816), buffer(896), buffer(128)
    local static_bytes, dynamic_bytes, operation_bytes = buffer(280), buffer(304), buffer(92)
    local header_bytes, mods_bytes, selection_bytes, map_bytes = buffer(24), buffer(1024), buffer(168), buffer(24)
    -- Tables each refresh fills again (never returned).
    local hashes, hash_by_id, initial, drawn, disabled, exclusion = {}, {}, {}, {}, {}, {}
    local by_id, by_hash, weight_family, weight_factor = {}, {}, {}, {}
    local settings_table = {candidates = {}, blockers = {}}
    for i = 1, 8 do settings_table.candidates[i] = {} end

    -- The bytes at address in `into` (default: the scratch buffer, for fields
    -- decoded before the next read). Memory that cannot be read is pending:
    -- the game rebuilds these records while screens change.
    local function read(address, size, into)
        into = into or scratch
        assert(size > 0 and size <= into.size, 'Mission read bound exceeded')
        if not api.read(address, size, into, 0) then error(DATA_UNAVAILABLE) end
        return into.data
    end
    local function ptr(address)
        local address_value = pointer_at(read(address, 8), 0)
        if not address_value then error(POINTER_UNAVAILABLE) end
        return address_value
    end
    local function count(address, maximum)
        local value = u32(read(address, 4), 0)
        assert(value <= maximum, 'Mission array bound exceeded')
        return value
    end

    -- 'map' or 'briefing' when one of them is on top of the UI screen stack.
    -- No UI state yet (while the game starts) is no forecast screen, not an
    -- error: errors now count toward stopping the mod.
    function self:screen()
        local manager = pointer_at(read(game + 0x347ce28, 8), 0)
        if not manager then return nil end
        local state = read(manager + 0x429c, 24)
        local n = u32(state, 20)
        if n < 1 or n > 5 then return nil end
        local top = u32(state, 4 * (n - 1))
        if top == 15 then return 'map' end
        if top == 14 then return 'briefing' end
        return nil
    end

    -- The key is built again only when the identity changes.
    local key, key1, key2, key3, key4, key5, key6
    local function key_of(seed, secondary, faction, difficulty, planet, mission)
        if key == nil or seed ~= key1 or secondary ~= key2 or faction ~= key3 or difficulty ~= key4
            or planet ~= key5 or mission ~= key6 then
            key1, key2, key3, key4, key5, key6 = seed, secondary, faction, difficulty, planet, mission
            key = seed .. ':' .. secondary .. ':' .. faction .. ':' .. difficulty .. ':' .. planet .. ':' .. mission
        end
        return key
    end
    local function identity(b, result)
        local faction, difficulty = b[8], b[9]
        if faction < 2 or faction > 4 or difficulty < 1 or difficulty > 10 then error(NOT_READY) end
        local mission = u16(b, 26)
        assert(mission < 256, 'Unknown mission type')
        local seed, secondary, planet = u32(b, 0), u32(b, 4), u32(b, 12)
        result.key = key_of(seed, secondary, faction, difficulty, planet, mission)
        result.seed, result.faction, result.difficulty, result.planet, result.mission =
            seed, faction, difficulty, planet, mission
    end
    -- A loaded descriptor matches when its identity bytes equal the selection's.
    local function same_identity(a, b)
        for i = 1, #IDENTITY do
            if a[IDENTITY[i]] ~= b[IDENTITY[i]] then return false end
        end
        return true
    end

    -- Joinable preview: mirror the native map lookup (0x1036670 / 0x1036710).
    -- A missing operation selection alone does not authorize cached preview
    -- data. The second result distinguishes an ended hover from a selected
    -- mission whose advertised packet or preview is still loading.
    local function joinable_selection(board)
        local selection = read(board + 1548964, 8)
        local id, group = u32(selection, 0), u32(selection, 4)
        if id >= 0x80000000 or group == 0 then
            local session = ptr(game + 0x3326aa0)
            local fallback = read(session + 5633600, 12)
            if id >= 0x80000000 then id = u32(fallback, 0) end
            if group == 0 then group = u32(fallback, 8) end
        end
        return id, group
    end
    local function joinable_row(board, total, id, group)
        local rows = read(board + 2044424, total * 20, bulk)
        local kind, index
        for i = 0, total - 1 do
            local at = i * 20
            if u32(rows, at + 8) == group and u32(rows, at + 12) == id then
                assert(not kind, 'Ambiguous joinable mission')
                kind, index = u32(rows, at), u32(rows, at + 4)
            end
        end
        return kind, index
    end
    local function joinable_preview(board, root)
        local planet = u32(read(board + 1548956, 4), 0)
        if planet >= 0x80000000 or read(board + 2064401, 1)[0] == 0 then return nil, false end
        local id, group = joinable_selection(board)
        if id >= 0x80000000 or group == 0 then return nil, false end
        local total = count(board + 2053224, 440)
        if total == 0 then return nil, true end
        local kind, index = joinable_row(board, total, id, group)
        local layout = LAYOUTS[kind]
        if not layout then return nil, true end
        local manager = ptr(game + 0x347ce80)
        if index >= count(manager + layout[2], layout[3]) then return nil, true end
        local record = manager + layout[1] + index * 1560
        if read(record + 1456, 1)[0] == 0 then return nil, true end
        local advertised = read(record + 944, 512, advertised_bytes)
        -- The native preview builder decodes this advertisement into the board
        -- descriptor and loads its canonical packet into the single preview slot.
        if u32(read(board + 4286668, 4), 0) ~= 0 then return nil, true end
        local loaded = read(root + 713400, 512, packet_bytes)
        if not same_text(advertised, loaded, 512) then return nil, true end
        return planet, true
    end

    -- Map: the highlighted local operation, or the hovered joinable mission.
    -- Returns preview_planet, hovered, operation_planet, operation_index.
    local function map_selection(board, root)
        local index = u32(read(board + 1548960, 4), 0)
        if index == 0xffffffff then return joinable_preview(board, root) end
        if index >= 110 then error(NO_MISSION) end
        local selected = read(board + 1012352 + index * 92, 92)
        if selected[52] == 0 then error(NO_MISSION) end
        return nil, nil, u16(selected, 16), index
    end
    -- Briefing: the owner record of the loaded mission.
    local function briefing_address()
        local manager = ptr(game + 0x3326e68)
        local n = count(manager + 26184, 1024)
        if n == 0 then error(NO_BRIEFING) end
        local rows = read(manager + 26192, n * 16, bulk)
        local selected
        for i = 0, n - 1 do
            if u32(rows, 16 * i + 8) == 235 then
                assert(not selected, 'Ambiguous briefing owner')
                selected = pointer_at(rows, 16 * i)
                if not selected then error(NO_OWNER) end
            end
        end
        if not selected then error(NO_OWNER) end
        return selected + 1072
    end

    -- Fills `result` (a new table when none is given) with the selected
    -- mission's identity and the records a sample reads.
    function self:descriptor(screen, result)
        local root = ptr(game + 0x3326340)
        local controller = ptr(root + 0xae288)
        local board = ptr(game + 0x347cee8)
        local address = board + 0x4168d0
        local preview_planet, hovered, operation_planet, operation_index
        if screen == 'briefing' then
            address = briefing_address()
        else
            preview_planet, hovered, operation_planet, operation_index = map_selection(board, root)
            if not preview_planet and not operation_index then return nil, hovered end
        end
        result = result or {}
        local bytes = read(address, 200, descriptor_bytes)
        identity(bytes, result)
        -- The native modifier/stamp path consumes the loaded controller.
        -- A stale controller cannot authorize a full composition forecast.
        result.controller_matches = same_identity(bytes, read(controller + 8, 200, loaded_bytes))
        result.address, result.controller, result.board, result.root = address, controller, board, root
        result.preview_planet = preview_planet
        result.operation_planet, result.operation_index = operation_planet, operation_index
        result.screen = screen
        return result, hovered
    end

    local function settings(snapshot)
        local b = read(game + 0x328d2a0 + (snapshot.difficulty - 1) * 816, 816, settings_bytes)
        local start, fallback = CANDIDATES[snapshot.faction], FALLBACKS[snapshot.faction]
        local result = settings_table
        result.draws = u32(b, 272)
        result.fallback = resolve.from_native(u32(b, fallback + 32))
        for i = 0, 7 do
            local at, row = start + i * 12, result.candidates[i + 1]
            row.id, row.weight, row.only_when_empty = resolve.from_native(u32(b, at)), f32(b, at + 4), b[at + 8] ~= 0
            result.blockers[i + 1] = resolve.from_native(u32(b, fallback + i * 4))
        end
        return result
    end

    -- Modifier definitions: enemy tags by ID (category 40), spawn-weight
    -- scales by ID (category 72: one enemy family's groups, native group
    -- weight 0x94a0a0) and the first ID of each hash.
    local function definitions(hashes_now)
        clear(by_id) clear(by_hash) clear(weight_family) clear(weight_factor)
        local defs = ptr(game + 0x347cd98)
        local dn = count(defs + 53248, 1024)
        if dn == 0 then return end
        local rows = read(defs, dn * 52, bulk)
        for i = 0, dn - 1 do
            local at = i * 52
            local id, category, kind = u32(rows, at), u32(rows, at + 4), u32(rows, at + 24)
            if category == 40 and kind == 13 then
                by_id[id] = assert(hashes_now[u32(rows, at + 28)], 'Unknown campaign enemy tag')
            end
            if category == 72 and kind == 13 and u32(rows, at + 36) == 2 then
                weight_family[id], weight_factor[id] = u32(rows, at + 28), f32(rows, at + 44)
            end
            local hash = u32(rows, at + 8)
            if by_hash[hash] == nil then by_hash[hash] = id end
        end
    end

    -- One campaign modifier: its enemy tag, and its spawn weight once per ID.
    -- zone is the sample's weight table, emptied at the start of each
    -- campaign read; applied holds the IDs applied in that read.
    local zone, applied = nil, {}
    local function apply(id)
        if not id then return end
        resolve.add(initial, by_id[id])
        local family = weight_family[id]
        if family and not applied[id] then
            applied[id] = true
            zone[family] = (zone[family] or 1) * weight_factor[id]
        end
    end
    local function add_ids(b, at, length, maximum)
        assert(length <= maximum, 'Too many campaign modifiers')
        for i = 0, length - 1 do apply(u32(b, at + i * 4)) end
    end
    local function event_modifiers(data, planet, index)
        local event = read(data + 470104 + 2496 * index, 2496, bulk)
        local pn = u32(event, 2480)
        assert(pn <= 32, 'Too many event planets')
        local applies = pn == 0
        for j = 0, pn - 1 do
            if u32(event, 2352 + 4 * j) == planet then applies = true end
        end
        if applies then add_ids(event, 2336, u32(event, 2348), 3) end
    end
    local function planet_modifiers(data, planet, static)
        local selected = read(data + 304 * planet + 286952, 132, bulk)
        add_ids(selected, 0, u32(selected, 128), 32)
        add_ids(static, 184, u32(static, 200), 4)
        for i = 0, count(data + 494868, 4) - 1 do
            local env = read(data + 494696 + i * 44, 44)
            if u32(env, 0) == planet then add_ids(env, 4, u32(env, 36), 8) end
        end
        for i = 0, count(data + 490072, 8) - 1 do event_modifiers(data, planet, i) end
    end

    -- Operation templates: the highlighted local operation's modifier hashes.
    local function find_operation(data, planet, id)
        for i = 0, count(data + 155672, 512) - 1 do
            local operation = read(data + 143384 + 24 * i, 24)
            if u32(operation, 0) == planet and u32(operation, 4) == id then return operation end
        end
        return nil
    end
    local function apply_template(slot)
        local template = ptr(slot)
        local total_mods = count(template + 96, 256)
        if total_mods == 0 then return end
        local list = read(ptr(template + 88), total_mods * 4, mods_bytes)
        for j = 0, total_mods - 1 do apply(by_hash[u32(list, 4 * j)]) end
    end
    local function template_modifiers(board, template_id)
        local header = read(board + 0x1f8908, 24, header_bytes)
        local values, total = pointer_at(header, 0), u32(header, 16)
        assert(total <= 4096, 'Too many operation templates')
        if not values or total == 0 then return end
        local keys = read(assert(pointer_at(header, 8)), total * 4, bulk)
        for i = 0, total - 1 do
            if u32(keys, 4 * i) == template_id then return apply_template(values + 8 * i) end
        end
    end
    local function operation_modifiers(board, data, planet, index)
        local selected = read(board + 1012352 + 92 * index, 92, operation_bytes)
        assert(u16(selected, 16) == planet, 'Operation planet does not match this mission')
        local category = u32(selected, 28)
        if selected[52] == 0 or category >= 14 or read(game + 0x32e98e0 + 168 * category + 9, 1)[0] == 0 then
            return
        end
        local operation = find_operation(data, u16(selected, 16), selected[24])
        local operation_id = operation and u32(operation, 4)
        operation = operation_id and find_operation(data, planet, operation_id)
        if operation then template_modifiers(board, u32(operation, 8)) end
    end
    local function local_operation(snapshot, board, data, planet)
        local selected_index = u32(read(board + 1548960, 4), 0)
        assert(selected_index <= 110 or selected_index == 0xffffffff, 'Invalid operation selection')
        assert(not snapshot.operation_index or selected_index == snapshot.operation_index,
            'Operation changed during read')
        if not snapshot.preview_planet and selected_index < 110 then
            operation_modifiers(board, data, planet, selected_index)
        end
    end

    -- Global modifiers in scope: type 17 adds an enemy tag; type 15 war
    -- effects scale one family's group weights (native 0x12e3c00).
    local function global_entry(war, globals, at)
        local total = u32(globals, at + 80)
        assert(total <= 5, 'Too many global modifier entries')
        for j = 0, total - 1 do
            local kind = globals[at + 16 * j]
            if kind == 17 then resolve.add(initial, resolve.from_native(u32(globals, at + 16 * j + 4))) end
            if kind == 15 then
                local family = u32(globals, at + 16 * j + 4)
                war[family] = (war[family] or 1) * f32(globals, at + 16 * j + 8)
            end
        end
    end
    -- Fills war (emptied first); returns it, or nil when no effect applies.
    local function war_effects(planet, dynamic, war)
        clear(war)
        local faction, region = u32(dynamic, 36), u32(dynamic, 64)
        local globals = read(ptr(game + 0x346d518), 32 * 356, bulk)
        for i = 0, 31 do
            local at = i * 356
            local scope, value, filter = globals[at + 84], u32(globals, at + 88), u32(globals, at + 92)
            local applies = scope == 3 or scope == 0 and value == planet
                or scope == 1 and value == region or scope == 2 and value == faction
            if applies and (filter == 0 or filter == faction) then global_entry(war, globals, at) end
        end
        return next(war) and war or nil
    end

    -- Map previews can be on a different planet from the active operation.
    -- Use the advertised planet for remote hovers or the highlighted local
    -- operation's planet. Check its hash before applying campaign inputs.
    local function campaign_planet(snapshot, board, data)
        local planet = snapshot.preview_planet or snapshot.operation_planet or count(board + 1548952, 511)
        local n = count(board + 1197132, 512)
        assert(planet < n, 'Planet data changed')
        if not snapshot.preview_planet and not snapshot.operation_planet then
            assert(u32(read(data + 495200, 4), 0) == planet, 'Planet data changed')
        end
        return planet
    end
    -- The sample keeps its two weight tables (zone_weights, war_weights) and
    -- refills them on every read; zone and war name them while not empty.
    local function campaign(snapshot, hashes_now)
        local board, root = snapshot.board, snapshot.root
        local data = board + 1053752
        local planet = campaign_planet(snapshot, board, data)
        local static = read(data + 280 * planet, 280, static_bytes)
        assert(u32(static, 24) == snapshot.planet, 'Selected planet does not match this mission')
        local dynamic = read(data + 304 * planet + 286752, 304, dynamic_bytes)
        local session = ptr(game + 0x347cef0)
        -- session+92134 (0x167e6): the game reads it as a flag in six places on build 25480438. The old
        -- 92102 was an older build's offset; on 25480438 it held unrelated data (0xa4 in play), which gated
        -- every campaign modifier off, so Hive Worlds never listed Hive Lords.
        local gated = read(session + 92134, 1)[0] ~= 0 or read(root + 4205, 1)[0] ~= 0
            or read(root + 4217, 1)[0] ~= 0
        definitions(hashes_now)
        zone = snapshot.zone_weights or {}
        snapshot.zone_weights, snapshot.war_weights = zone, snapshot.war_weights or {}
        clear(zone) clear(applied)
        if not gated then
            planet_modifiers(data, planet, static)
            local_operation(snapshot, board, data, planet)
        end
        local war = war_effects(planet, dynamic, snapshot.war_weights)
        snapshot.zone, snapshot.war = next(zone) and zone or nil, war
        return true
    end

    local function stamp_address(selection)
        local index, variant = selection[162], selection[161]
        if index == 255 then return nil end
        local owner = assert(pointer_at(selection, 0))
        if u32(selection, 8) ~= 2915250090 then return ptr(owner) end
        if variant == 255 then return nil end
        return ptr(ptr(owner + 40) + 24 * variant + 8) + 456 * index
    end
    local function stamp(snapshot)
        local controller = snapshot.controller
        local level = ptr(controller + 648)
        local explicit = read(level + 9160276, 16)
        local n = u32(explicit, 12)
        assert(n <= 3, 'Too many explicit tags')
        for i = 0, n - 1 do resolve.add(initial, resolve.from_native(u32(explicit, 4 * i))) end
        if not pointer_at(read(controller, 8), 0) or count(level + 18510124, 100000) == 0 then return end
        local address = stamp_address(read(level + 9017008, 168, selection_bytes))
        if address then resolve.add(initial, resolve.from_native(u32(read(address + 208, 4), 0))) end
    end

    local function excluded_in(map, key)
        local header = read(map, 24, map_bytes)
        local capacity, empty, multiplier = u32(header, 8), u32(header, 12), u32(header, 16)
        assert(capacity <= 65536 and (capacity == 0 or bit.band(capacity, capacity - 1) == 0),
            'Unexpected configuration map')
        if capacity == 0 then return false end
        local data = assert(pointer_at(header, 0))
        local product = mul32(key, multiplier)
        for probe = 0, math.min(capacity, 128) - 1 do
            local slot = bit.band(product + probe, capacity - 1)
            local found = u32(read(data + 48 * slot, 4), 0)
            if found == key then return true end
            if found == empty then return false end
        end
        assert(capacity <= 128, 'Configuration lookup bound exceeded')
        return false
    end
    local function excluded_by_config(tag_hash)
        local manager = ptr(game + 0x347cdf8)
        local key = resolve.exclusion_key(tag_hash)
        for i = 1, #CONFIG_MAPS do
            if excluded_in(manager + CONFIG_MAPS[i], key) then return true end
        end
        return false
    end

    local function tag_hashes()
        local b = read(game + 0x21e1920, 32 * 4, hash_bytes)
        clear(hashes)
        for i = 0, 31 do
            local hash = u32(b, i * 4)
            local tag = resolve.from_native(i)
            hashes[hash], hash_by_id[tag] = tag, hash
        end
    end
    -- Campaign and level tags into `initial`; true when both resolved.
    local function initial_tags(snapshot, unresolved)
        clear(initial)
        local ok, result = pcall(campaign, snapshot, hashes)
        if not ok then
            clear(initial)
            unresolved[#unresolved + 1] = describe(result)
        end
        local complete = ok and result and snapshot.controller_matches
        if snapshot.controller_matches then
            local good, reason = pcall(stamp, snapshot)
            if not good then unresolved[#unresolved + 1] = describe(reason) end
            complete = complete and good
        else
            unresolved[#unresolved + 1] = 'Hovered mission differs from the loaded mission'
        end
        return complete
    end
    -- Tags the backend configuration disables; false when a lookup failed.
    local function disabled_tags(tags, unresolved)
        clear(disabled)
        local complete = true
        for _, tag in ipairs(tags) do
            local ok, value = pcall(excluded_by_config, hash_by_id[tag])
            if ok then disabled[tag] = value else
                complete = false
                unresolved[#unresolved + 1] = describe(value)
            end
        end
        return complete
    end
    -- Native build 25480438 uses 896-byte mission records, a conditional
    -- additional tag, and eight exclusions (formerly one).
    local function horde_mode(config)
        if config[0x34] ~= 2 then return false end
        for i = 1, #HORDE_MARKER do
            if config[0x35f + i] ~= HORDE_MARKER[i] then return false end
        end
        return true
    end
    local function mission_exclusions(config)
        clear(exclusion)
        for i = 0, 7 do
            local native = u32(config, 0x14 + 4 * i)
            if native ~= 0 then exclusion[resolve.from_native(native)] = true end
        end
    end
    -- The selection, screen and highlighted operation are still the ones read.
    local function unchanged(snapshot, screen)
        if not same_bytes(read(snapshot.address, 200, recheck_bytes), descriptor_bytes.data, 200)
            or self:screen() ~= screen then
            return false
        end
        local board = snapshot.board
        if snapshot.preview_planet and u32(read(board + 1548956, 4), 0) ~= snapshot.preview_planet then
            return false
        end
        if snapshot.operation_index and (u32(read(board + 1548960, 4), 0) ~= snapshot.operation_index
            or u16(read(board + 1012352 + 92 * snapshot.operation_index + 16, 2), 0) ~= snapshot.operation_planet)
            then
            return false
        end
        return true
    end

    -- The full forecast inputs, in `result` (a new table when none is given;
    -- a table passed again is refilled, its lists reused).
    function self:sample(screen, result)
        local snapshot = self:descriptor(screen, result)
        if not snapshot then return nil end
        tag_hashes()
        local unresolved = snapshot.unresolved or {}
        clear(unresolved)
        snapshot.unresolved, snapshot.zone, snapshot.war = unresolved, nil, nil
        local complete = initial_tags(snapshot, unresolved)
        local tags = resolve.base(snapshot.seed, settings(snapshot), initial, drawn)
        local config = read(game + 0x3773420 + 896 * snapshot.mission, 896, config_bytes)
        if horde_mode(config) then resolve.add(tags, 31) end
        complete = disabled_tags(tags, unresolved) and complete
        mission_exclusions(config)
        snapshot.tags = resolve.filter(tags, exclusion, disabled, snapshot.tags)
        snapshot.complete = complete
        if not unchanged(snapshot, screen) then return nil end
        return snapshot
    end
    -- The 0.5 s refresh stays interpreted: compiled, its row loops would add
    -- traces to the game's shared code cache for a path that runs twice a
    -- second. The per-frame checks (screen, descriptor) and the readers and
    -- decoders they share compile.
    if jit and jit.off then
        for _, fn in ipairs({self.sample, tag_hashes, initial_tags, campaign, campaign_planet, definitions, apply,
                             add_ids, event_modifiers, planet_modifiers, find_operation, apply_template,
                             template_modifiers, operation_modifiers, local_operation, global_entry, war_effects,
                             stamp_address, stamp, excluded_in, excluded_by_config, disabled_tags, horde_mode,
                             mission_exclusions, unchanged, settings}) do
            jit.off(fn)
        end
    end
    return self
end

return M
