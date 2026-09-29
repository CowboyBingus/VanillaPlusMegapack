-- Nearby lobbies: limits the game's own lobby searches (Galactic Map scanner
-- and quickplay) to the player's continent.
--
-- The search builder adds "string_key6 ne <continent>" for every continent
-- whose pair flag (own continent, other continent) is a false bool in the
-- override config (lookup 0x12e7990: the peer-synced table first, then
-- OnlineOverrideData). The server ships 16 false pairs; this module makes the
-- rest of the player's own row false in OnlineOverrideData, in one write, and
-- puts the table back byte for byte when switched off or at shutdown. No extra
-- search requests are made.
--
-- The game only replaces OnlineOverrideData whole: a config download whose
-- checksum (stored after the entries) differs copies the new table over it; an
-- identical download leaves it alone. The mod never changes the stored
-- checksum, so its flags survive identical downloads and a new table shows up
-- as a new checksum. The peer-synced table (the host sends it to its clients)
-- is never written.
local bit = require('bit')
local R = {}

R.CONFIG_PTR = 0x347cdf8          -- override config object
R.SYNCED_TABLE = 0x12078          -- OnlineOverrideDataPeerSynced (read only)
R.TABLE = 0xc050                  -- OnlineOverrideData (the continent pairs)
-- Table: +0 entries, +8 capacity, +12 empty key, +16 probe multiplier, +20 root
-- key, +24 entry count, entries inline from +0x20, entry checksum at +0x6020.
R.ENTRIES, R.COUNT, R.CHECKSUM = 0x20, 24, 0x6020
R.CAPACITY, R.ENTRY_SIZE = 512, 48
R.SPAN = R.ENTRIES + R.CAPACITY * R.ENTRY_SIZE  -- header and entries, checksum excluded
-- Entry: +0 key, +8 name, +12 parent key, +16 key, +20 type, +24 value,
-- +32 previous key, +36 next key, +40 weight (100.0f), +44 peer-synced flag.
R.TYPE_BOOL = 7
R.WEIGHT = 0x42c80000
R.KEY_WORDS = {0x673bc524, 0x5df5d36b}
R.CONTINENTS = {{'AF', 0x9061bf63}, {'AN', 0xc59a4447}, {'AS', 0x617288e9}, {'EU', 0x0fab5b27},
                {'NA', 0x29ce1e3f}, {'OC', 0xccc7bf91}, {'SA', 0xd044af30}}
R.CONTINENT_IDS_RVA = 0x21d45b0   -- the game's own copy of the ids above
R.VERIFY_FRAMES = 120             -- how often the flags are checked while the option is on

-- game.dll code this module depends on (Steam build 25480438).
R.CODE = {
    -- Search builder: the pair key words, continent code and id tables, 7 continents.
    {rva = 0x133b1a3, name = 'continent filter', bytes =
        '\199\133\192\0\0\0\36\197\59\103\72\141\53\100\127\233\0\199\133\196\0\0\0\107\211\245\93\76\141\53'
        .. '\235\147\233\0\65\188\7\0\0\0'},
    -- ...looks the pair up in the config object and skips unless it is a false bool.
    {rva = 0x133b229, name = 'continent flag check', bytes =
        '\72\139\13\200\27\20\2\65\139\215\232\88\199\250\255\72\133\192\116\33\131\120\12\7\117\27\68\56'
        .. '\104\16\117\21'},
    -- Lookup: peer-synced table (+0x12078) first, then +0xC050; open addressing.
    {rva = 0x12e7990, name = 'override lookup', bytes =
        '\72\137\92\36\8\72\137\108\36\16\72\137\116\36\24\72\137\124\36\32\65\86\133\210\76\139\209\185\120'
        .. '\32\1\0\184\40\96\0\0\15\69\193\68\139\242\73\3\194\51\210'},
    -- Config download: replaces +0xC050 only when the stored checksum differs.
    {rva = 0x103f61d, name = 'override refresh', bytes =
        '\139\131\112\32\1\0\65\139\141\32\96\0\0\137\68\36\40\137\76\36\44\59\193\116\62\65\139\69\20\72\141'
        .. '\139\112\192\0\0\137\131\100\192\0\0\73\141\85\32\65\139\69\24\65\184\0\96\0\0\137\131\104\192\0\0'
        .. '\232\144\146\5\1\65\139\133\32\96\0\0\137\131\112\32\1\0'},
}

local K = 0x5bd1e995
local function u32(x) return x % 4294967296 end
-- (a * b) mod 2^32 without losing precision in doubles.
local function mul32(a, b)
    local low, high = a % 65536, (a - a % 65536) / 65536
    return (low * b + ((high * b) % 65536) * 65536) % 4294967296
end
-- The game's key combine (murmur-style, 32-bit); a child's key is its parent's
-- key combined with its name.
function R.combine(words)
    local h = words[1]
    for i = 2, #words do
        local a = mul32(K, words[i])
        local mixed = u32(bit.bxor(a, bit.rshift(a, 24)))
        h = u32(bit.bxor(mul32(K, mixed), mul32(K, h)))
    end
    return h
end
R.mul32 = mul32

-- Entry address for key in the table, or nil and the first empty slot on its
-- probe path. taken: planned slots that count as occupied. Same probe order as
-- the game (empty checked before the key).
function R.lookup(api, table_address, key, taken)
    local entries, capacity = api.load64(table_address), api.load32(table_address + 8)
    local empty, multiplier = api.load32(table_address + 12), api.load32(table_address + 16)
    local start = mul32(key, multiplier)
    for i = 0, capacity - 1 do
        local entry = entries + bit.band(start + i, capacity - 1) * R.ENTRY_SIZE
        local found = api.load32(entry)
        if found == empty then
            if not (taken and taken[entry]) then return nil, entry end
        elseif found == key then
            return entry
        end
    end
    return nil, nil
end

local function is_false_bool(api, entry)
    return api.load32(entry + 20) == R.TYPE_BOOL and api.load8(entry + 24) == 0
end

-- Per own continent: the row key, the status text and each (own, other) pair
-- key, computed once.
local ROWS, BY_CODE = {}, {}
for own, continent in ipairs(R.CONTINENTS) do
    local row = {key = R.combine({R.KEY_WORDS[1], R.KEY_WORDS[2], continent[2]}), name = continent[1],
                 status = 'my continent only (' .. continent[1] .. ')'}
    for index, other in ipairs(R.CONTINENTS) do
        if index ~= own then
            row[#row + 1] = {key = R.combine({R.KEY_WORDS[1], R.KEY_WORDS[2], continent[2], other[2]}),
                             id = other[2], name = other[1]}
        end
    end
    ROWS[own] = row
    BY_CODE[continent[1]:byte(1) * 256 + continent[1]:byte(2)] = own
end
R.ROWS = ROWS

function R.new(api, game, natives, status, note)
    local self = {}
    local mode, frames = 1, 0
    -- Entries written into the applied table, by address: {address, key,
    -- original}; original is nil for an added entry. watch lists them for the
    -- periodic check.
    local managed, watch = {}, {}
    -- What the last attempt saw: the config object, both table checksums and
    -- the continent. The periodic check only plans again when one changes.
    local applied = {config = 0, checksum = 0, synced = 0, own = 0}
    local checked_config, bad_config, last_wait = 0, 0, nil
    status.region = 'game default'

    local function set_status(text)
        status.region = text
        status.revision = (status.revision or 0) + 1
    end

    -- True when a table has the layout the game's code uses (inline 512-slot entries).
    local function table_ok(address)
        return api.read64(address) == address + R.ENTRIES and api.read32(address + 8) == R.CAPACITY
            and api.read32(address + 16) ~= 0 and api.read32(address + R.CHECKSUM) ~= nil
    end

    -- The config object, or nil and a reason. A new object is checked once with
    -- guarded reads; later calls use direct loads.
    local function config_object()
        local config = api.load64(game + R.CONFIG_PTR)
        if config == 0 or config % 8 ~= 0 then return nil, 'override data unavailable' end
        if config ~= checked_config then
            if config == bad_config or not table_ok(config + R.TABLE) or not table_ok(config + R.SYNCED_TABLE) then
                bad_config = config
                return nil, 'override table layout changed'
            end
            checked_config = config
        end
        if api.load32(config + R.TABLE + R.COUNT) == 0 then return nil, 'override data not loaded' end
        return config
    end

    -- The player's continent index into R.CONTINENTS, or nil (not known before
    -- sign-in). The engine returns its two-letter code or null.
    function self.continent()
        -- A 64-bit return arrives as cdata; the pointer itself fits a number.
        local text = tonumber(natives.continent(natives.lobby_api))
        if text == 0 or api.load8(text + 2) ~= 0 then return nil end
        return BY_CODE[api.load8(text) * 256 + api.load8(text + 1)]
    end

    -- Once per session: the continent ids and the code above.
    function self.verify()
        for index, continent in ipairs(R.CONTINENTS) do
            if api.load32(game + R.CONTINENT_IDS_RVA + (index - 1) * 4) ~= continent[2] then
                return false, 'continent table changed'
            end
        end
        for _, code in ipairs(R.CODE) do
            if api.bytes(game + code.rva, #code.bytes) ~= code.bytes then return false, code.name .. ' changed' end
        end
        return true
    end

    local function push(words, ...)
        for i = 1, select('#', ...) do words[#words + 1] = select(i, ...) end
    end

    -- True when no pair of row needs a write. Loads only, no allocation.
    local function settled(main, synced, row)
        for i = 1, #row do
            local key = row[i].key
            if not R.lookup(api, synced, key) then
                local entry = R.lookup(api, main, key)
                if not entry or (api.load32(entry + 20) == R.TYPE_BOOL and api.load8(entry + 24) ~= 0) then
                    return false
                end
            end
        end
        return true
    end

    -- The writes that make every pair of row a false bool: words for
    -- api.write_words on the table, the changes to record and the pairs left to
    -- the peer-synced table, or nil and a reason. Loads only.
    local function plan(main, synced, row)
        local words, changes, taken, skipped, added = {}, {}, {}, {}, 0
        for i = 1, #row do
            local pair = row[i]
            local shadow = R.lookup(api, synced, pair.key)
            if shadow then
                -- The peer-synced table answers first; it is never written.
                if not is_false_bool(api, shadow) then skipped[#skipped + 1] = pair.name end
            else
                local entry, slot = R.lookup(api, main, pair.key, taken)
                if entry then
                    if api.load32(entry + 20) ~= R.TYPE_BOOL then
                        skipped[#skipped + 1] = pair.name
                    elseif api.load8(entry + 24) ~= 0 then
                        push(words, entry - main + 24, 0)
                        changes[#changes + 1] = {address = entry, key = pair.key, original = api.load32(entry + 24)}
                    end
                elseif slot then
                    -- A new entry like the server's own; the key goes in last.
                    taken[slot] = true
                    local o = slot - main
                    push(words, o + 4, 0, o + 8, pair.id, o + 12, row.key, o + 16, pair.key, o + 20, R.TYPE_BOOL,
                         o + 24, 0, o + 28, 0, o + 32, 0, o + 36, 0, o + 40, R.WEIGHT, o + 44, 0, o, pair.key)
                    changes[#changes + 1] = {address = slot, key = pair.key}
                    added = added + 1
                else
                    return nil, 'override table full'
                end
            end
        end
        if added > 0 then push(words, R.COUNT, api.load32(main + R.COUNT) + added) end
        return words, changes, skipped
    end

    -- Makes the player's row false. Returns the number of entries written
    -- (0 when already in place), or nil and a reason.
    local function write_row(config, own)
        local main, synced, row = config + R.TABLE, config + R.SYNCED_TABLE, ROWS[own]
        if settled(main, synced, row) then return 0 end
        local words, changes, skipped = plan(main, synced, row)
        if not words then return nil, changes end
        if not api.write_words(main, R.SPAN, words) then return nil, 'write refused' end
        for _, change in ipairs(changes) do managed[change.address] = change end
        if #skipped > 0 then
            note('nearby lobbies: ' .. row.name .. '->' .. table.concat(skipped, ', ' .. row.name .. '->')
                .. ' set by the peer-synced config; left unchanged')
        end
        return #changes
    end

    local function apply()
        local config, why = config_object()
        if not config then return nil, why end
        local own = self.continent()
        if not own then return nil, 'continent unknown' end
        local checksum = api.load32(config + R.TABLE + R.CHECKSUM)
        -- A new object or checksum means the game replaced the table: old records are stale.
        if config ~= applied.config or checksum ~= applied.checksum then managed = {} end
        applied.config, applied.checksum, applied.own = config, checksum, own
        applied.synced = api.load32(config + R.SYNCED_TABLE + R.CHECKSUM)
        local written
        written, why = write_row(config, own)
        watch = {}
        for _, change in pairs(managed) do watch[#watch + 1] = change end
        if not written then return nil, why end
        if status.region ~= ROWS[own].status then set_status(ROWS[own].status) end
        last_wait = nil
        return written
    end

    -- True when nothing changed since the last attempt: the same tables, the
    -- same continent and every written entry in place. Direct loads only; a
    -- refused write or a full table is not tried again until this changes.
    local function unchanged()
        local config = api.load64(game + R.CONFIG_PTR)
        if config == 0 or config ~= applied.config
            or api.load32(config + R.TABLE + R.CHECKSUM) ~= applied.checksum
            or api.load32(config + R.SYNCED_TABLE + R.CHECKSUM) ~= applied.synced
            or self.continent() ~= applied.own then
            return false
        end
        for i = 1, #watch do
            local change = watch[i]
            if api.load32(change.address) ~= change.key or api.load8(change.address + 24) ~= 0 then return false end
        end
        return true
    end

    -- Puts the applied table back byte for byte: flipped flags get their value
    -- again and added entries are removed (the game only ever replaces this
    -- table whole, so no other entry's probe path runs through them). Records
    -- of a replaced table are dropped without writing.
    function self.restore()
        local restored = 0
        local config = api.load64(game + R.CONFIG_PTR)
        local main = config + R.TABLE
        if next(managed) and config ~= 0 and config == applied.config
            and api.load32(main + R.CHECKSUM) == applied.checksum then
            local words, removed, empty = {}, 0, api.load32(main + 12)
            for address, change in pairs(managed) do
                if api.load32(address) == change.key and api.load8(address + 24) == 0 then
                    local o = address - main
                    if change.original then
                        push(words, o + 24, change.original)
                    else
                        push(words, o, empty)
                        for field = 4, R.ENTRY_SIZE - 4, 4 do push(words, o + field, 0) end
                        removed = removed + 1
                    end
                    restored = restored + 1
                end
            end
            if removed > 0 then push(words, R.COUNT, api.load32(main + R.COUNT) - removed) end
            if #words > 0 and not api.write_words(main, R.SPAN, words) then restored = 0 end
        end
        managed, watch = {}, {}
        applied.config, applied.checksum, applied.synced, applied.own = 0, 0, 0, 0
        set_status('game default')
        return restored
    end

    -- Reports a reason once; the next check tries again.
    local function wait(why)
        if why == last_wait then return end
        last_wait = why
        set_status('my continent only: waiting (' .. why .. ')')
        note('nearby lobbies: waiting (' .. why .. ')')
    end

    -- 1: game default, 2: own continent only.
    function self.set_mode(value)
        if value == mode then return true end
        mode = value
        if mode == 2 then
            frames, last_wait = 0, nil
            local written, why = apply()
            if not written then wait(why); return false end
            note('nearby lobbies: own continent only, ' .. written .. ' flags written')
            return true
        end
        note('nearby lobbies: game default, ' .. self.restore() .. ' flags restored')
        return true
    end

    -- Every VERIFY_FRAMES frames while the option is on: write again after the
    -- game replaced the table (or when the first attempt had to wait).
    function self.step()
        if mode ~= 2 then return end
        frames = frames + 1
        if frames < R.VERIFY_FRAMES then return end
        frames = 0
        if unchanged() then return end
        local written, why = apply()
        if not written then
            wait(why)
        elseif written > 0 then
            last_wait = nil
            note('nearby lobbies: re-applied, ' .. written .. ' flags written')
        end
    end

    function self.mode() return mode end
    return self
end

return R
