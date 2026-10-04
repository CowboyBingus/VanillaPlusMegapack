-- Diagnostic timeline recorder for the kick crash (test builds only; see
-- docs/TECHNICAL.md). Read-only: it never writes game memory
-- and calls no game code.
--
-- While the host has a squad on the ship it keeps each frame's starting state
-- of the engine's package queue and a copy of the resource manager's in-use
-- table (an unload crashes on purpose while its resource has an entry there).
-- A capture starts at the mod's kick or when a player leaves the session (the
-- game's KICK, a voluntary leave) and logs, for every frame with a change: the
-- queue entries added and processed, the in-use entries gone, changed and new
-- (resource name hash, high 32 bits), the unload pause flag and the PlayFab
-- lobby's member count (a kicked client leaves the lobby itself). It ends
-- D.CAPTURE_AFTER after the last queue, pause, lobby or session event. The log
-- is flushed per line, so a crash keeps the timeline up to its frame.
local D = {}

-- helldivers2.exe (build 25480438)
D.APP_PTR = 0x1a10208          -- the application
D.PACKAGE_MANAGER = 0x400      -- application -> package manager
D.RESOURCE_MANAGER = 0x210     -- package manager -> resource manager
D.QUEUE, D.QUEUE_STRIDE, D.QUEUE_SIZE = 0x218, 24, 512   -- ring: package id u64, override u64, load flag
D.QUEUE_LOAD = 0x10            -- entry byte: 1 load, 0 unload
D.QUEUE_HEAD, D.QUEUE_TAIL, D.UNLOAD_PAUSED = 0x321c, 0x3220, 0x3224
D.IN_USE_SLOTS, D.IN_USE_ENTRIES, D.STRICT = 0x350, 0x358, 0x384
D.IN_USE_STRIDE = 24           -- entry: resource u64, count u32, name hash high 32 bits, next i32 (< 0 empty)
D.IN_USE_COUNT, D.IN_USE_NAME, D.IN_USE_NEXT = 8, 12, 16
D.IN_USE_MAX = 8192            -- slots copied at most
-- game.dll: the PlayerHistory system (loadouts of the session's players)
D.HISTORY_PTR, D.HISTORY_COUNT, D.HISTORY_STRIDE = 0x347ce50, 0x2d200, 0x1690
D.H_INACTIVE, D.H_KICKED, D.H_LOADOUT, D.H_LOAD_TYPE = 40, 42, 47, 0xa28 + 2532
D.HISTORY_MAX = 32

D.CAPTURE_AFTER = 10           -- seconds a capture runs after its last event
D.CAPTURE_MAX = 180            -- and at most
D.LIST_MAX = 48                -- items listed per kind in one log line

-- The code that fixes the layout above.
D.EXE_CODE = {
    {rva = 0x321030, name = 'package release API', bytes =
        '\72\139\209\72\139\13\206\241\110\1\72\139\137\0\4\0\0'},
    {rva = 0x6032a7, name = 'package queue', bytes =
        '\232\100\180\0\0\131\191\24\50\0\0\1\15\133\152\2\0\0\139\135\28\50\0\0\72\137\92\36\96\72\141'
        .. '\20\64\15\16\132\215\24\2\0\0\242\15\16\140\215\40\2\0\0\15\17\68\36\48\72\139\92\36\48\242\15'
        .. '\17\76\36\64'},
    {rva = 0x60345f, name = 'unload pause check', bytes = '\128\191\36\50\0\0\0'},
    {rva = 0x603bb4, name = 'package queue tail', bytes =
        '\65\139\142\32\50\0\0\141\65\1\37\255\1\0\0\65\137\134\32\50\0\0\72\141\4\73\73\141\60\198\72'
        .. '\141\4\73\72\137\159\24\2\0\0'},
    {rva = 0x603be6, name = 'resource manager', bytes = '\73\139\142\16\2\0\0'},
    {rva = 0x5f5bb6, name = 'in-use table', bytes =
        '\72\141\142\80\3\0\0\232\30\148\0\0\68\139\134\80\3\0\0\61\255\255\255\127\116\110\65\59\192\115'
        .. '\42\102\102\102\15\31\132\0\0\0\0\0\139\200\72\141\20\73\72\139\142\88\3\0\0\57\92\209\16\125\7'
        .. '\255\192\65\59\192\114\230\65\59\192\114\2\118\61\139\192\72\141\12\64\72\139\134\88\3\0\0\72'
        .. '\141\20\200\56\158\132\3\0\0\116\36'},
}
D.GAME_CODE = {
    {rva = 0x10908c7, name = 'player history', bytes =
        '\72\139\53\130\197\62\2\72\141\21\147\119\35\1\72\141\13\124\118\35\1\232\31\122\106\0\51\237'
        .. '\139\253\57\174\0\210\2\0\118\80\72\137\92\36\64\15\31\64\0\102\102\15\31\132\0\0\0\0\0\139\199'
        .. '\72\105\216\144\22\0\0\64\56\108\51\47\116\30\72\141\150\40\10\0\0\72\139\206\72\3\211\232\222'
        .. '\135\45\0\102\137\108\51\47\137\172\51\28\10\0\0'},
}

-- exe, game: module bases. note(message): the mod's log.
function D.new(api, game, exe, G, note)
    local self = {}
    local pm, rm = 0, 0
    local now_buf, last_buf, now_slots, last_slots = 0, 0, 0, 0
    local head, tail, paused = 0, 0, 0       -- queue state at the start of the last recorded frame
    local armed = false                      -- the last frame was recorded (differences are meaningful)
    local cache, snap = {ctx = 0}, G.new_snapshot()
    local seen_lo, seen_hi, seen_n = {}, {}, 0
    local kicked = {}                        -- peers the mod kicked, until they leave the session
    local names = {}                         -- in-use key -> name hash high 32 bits
    local base, spare = {}, {}               -- decoded in-use tables: the last frame's and a reused one
    local capture = nil
    local kick_tail = 0
    local members = -1                       -- PlayFab lobby members at the last recorded frame
    local out = 0                            -- output cells for the PlayFab reads (lobby_report)
    local pf = {}
    local playfab = api.module(G.PLAYFAB_DLL)
    if playfab then
        for name, export in pairs({keys = {'PFLobbyGetSearchPropertyKeys', 'LmGetKeys'},
                                   property = {'PFLobbyGetSearchProperty', 'LmGetProperty'},
                                   access = {'PFLobbyGetAccessPolicy', 'LmGetAccess'}}) do
            local address = api.export(playfab, export[1])
            if address then pf[name] = api.native(export[2], address) end
        end
    end

    function self.verify()
        for _, code in ipairs(D.EXE_CODE) do
            if api.bytes(exe + code.rva, #code.bytes) ~= code.bytes then return false, code.name .. ' changed' end
        end
        for _, code in ipairs(D.GAME_CODE) do
            if api.bytes(game + code.rva, #code.bytes) ~= code.bytes then return false, code.name .. ' changed' end
        end
        local app = api.read64(exe + D.APP_PTR)
        pm = app and app ~= 0 and api.read64(app + D.PACKAGE_MANAGER) or 0
        rm = pm ~= 0 and api.read64(pm + D.RESOURCE_MANAGER) or 0
        if not pm or not rm or pm == 0 or rm == 0 then return false, 'engine managers unavailable' end
        local slots, strict = api.read32(rm + D.IN_USE_SLOTS), api.read32(rm + D.STRICT)
        if not slots or slots == 0 or slots > D.IN_USE_MAX or not strict or not api.read32(pm + D.QUEUE_HEAD) then
            return false, 'engine tables unreadable'
        end
        now_buf = api.buffer(D.IN_USE_MAX * D.IN_USE_STRIDE)
        last_buf = api.buffer(D.IN_USE_MAX * D.IN_USE_STRIDE)
        out = api.buffer(64)
        note(string.format('diag: recorder ready; in-use table %d slots, strict %d; package queue head %d tail %d; '
            .. 'unload pause %d', slots, strict % 256, api.load32(pm + D.QUEUE_HEAD), api.load32(pm + D.QUEUE_TAIL),
            api.load8(pm + D.UNLOAD_PAUSED)))
        return true
    end

    function self.capturing() return capture ~= nil end

    -- The host's own PlayFab lobby: its access policy and search properties,
    -- which are what other hosts' searches match. string_key6 (the continent)
    -- is not printed; the location keys are lobby data, never search
    -- properties, and are not read.
    function self.lobby_report(ctx)
        if not (pf.keys and pf.property and pf.access) then
            note('diag: own lobby: PlayFab exports unavailable')
            return
        end
        local lobby = G.playfab_lobby(api, ctx)
        if not lobby then
            note('diag: own lobby: none')
            return
        end
        local handle = api.u64(api.load32(lobby + G.PL_HANDLE), api.load32(lobby + G.PL_HANDLE + 4))
        api.zero(out, 64)
        local parts = {}
        local result = pf.access(handle, out)
        parts[1] = result == 0 and ('access policy ' .. api.load32(out))
            or string.format('access policy error 0x%08X', result % 4294967296)
        result = pf.keys(handle, out + 8, out + 16)
        if result ~= 0 then
            parts[2] = string.format('search properties error 0x%08X', result % 4294967296)
        else
            local count, keys = api.load32(out + 8), api.load64(out + 16)
            for i = 0, math.min(count, 32) - 1 do
                local key_address = api.load64(keys + i * 8)
                local key = api.cstring(key_address, 64) or '?'
                local value = '?'
                if pf.property(handle, key_address, out + 24) == 0 then
                    value = api.cstring(api.load64(out + 24), 128) or ''
                end
                if key == 'string_key6' then value = '(continent, not logged)' end
                parts[#parts + 1] = key .. '=' .. value
            end
        end
        note('diag: own lobby: ' .. table.concat(parts, '; '))
    end

    local function copy_table(buffer)
        local slots, entries = api.load32(rm + D.IN_USE_SLOTS), api.load64(rm + D.IN_USE_ENTRIES)
        if slots == 0 or slots > D.IN_USE_MAX or entries == 0 then return 0 end
        if not api.read_block(entries, buffer, slots * D.IN_USE_STRIDE) then return 0 end
        return slots
    end

    -- The frame's starting state: the in-use table copied into now_buf (the
    -- last frame's copy stays in last_buf) and the queue fields.
    local function sample()
        now_buf, last_buf = last_buf, now_buf
        last_slots, now_slots = now_slots, copy_table(now_buf)
        return api.load32(pm + D.QUEUE_HEAD), api.load32(pm + D.QUEUE_TAIL), api.load8(pm + D.UNLOAD_PAUSED)
    end

    local function decode(buffer, slots, map)
        for key in pairs(map) do map[key] = nil end
        for i = 0, slots - 1 do
            local entry = buffer + i * D.IN_USE_STRIDE
            if api.load32(entry + D.IN_USE_NEXT) < 2147483648 then
                local key = api.load64(entry)
                if key ~= 0 then
                    map[key] = api.load32(entry + D.IN_USE_COUNT)
                    names[key] = api.load32(entry + D.IN_USE_NAME)
                end
            end
        end
        return map
    end

    local function size_of(map)
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        return n
    end

    local function listed(label, list)
        if #list == 0 then return nil end
        local shown = {}
        for i = 1, math.min(#list, D.LIST_MAX) do shown[i] = list[i] end
        local more = #list > D.LIST_MAX and string.format(' +%d more', #list - D.LIST_MAX) or ''
        return string.format('%s %d [%s%s]', label, #list, table.concat(shown, ' '), more)
    end

    local function entry_text(index)
        local entry = pm + D.QUEUE + index * D.QUEUE_STRIDE
        return string.format('%s %08x%08x', api.load8(entry + D.QUEUE_LOAD) ~= 0 and 'load' or 'unload',
            api.load32(entry + 4), api.load32(entry))
    end

    -- Queue entries in ring positions [from, to).
    local function span(from, to)
        local list, i = {}, from
        while i ~= to and #list < D.QUEUE_SIZE do
            list[#list + 1] = entry_text(i)
            i = (i + 1) % D.QUEUE_SIZE
        end
        return list
    end

    local function history_text(lo, hi)
        local history = api.read64(game + D.HISTORY_PTR)
        if not history or history == 0 then return 'no player history' end
        local count = api.read32(history + D.HISTORY_COUNT)
        if not count then return 'player history unreadable' end
        for i = 0, math.min(count, D.HISTORY_MAX) - 1 do
            local entry = history + i * D.HISTORY_STRIDE
            if api.load32(entry) == lo and api.load32(entry + 4) == hi then
                return string.format('history inactive %d kicked %d loadout %d type %d', api.load8(entry + D.H_INACTIVE),
                    api.load8(entry + D.H_KICKED), api.load8(entry + D.H_LOADOUT), api.load32(entry + D.H_LOAD_TYPE))
            end
        end
        return 'no player history entry'
    end

    local function log(now, text)
        note(string.format('diag %+.3fs f%d: %s', now - capture.started, capture.frames, text))
    end

    -- Guarded reads (captures only); -1 when there is no lobby.
    local function lobby_members(ctx)
        if ctx == 0 then return -1 end
        local lobby = G.playfab_lobby(api, ctx)
        return lobby and api.read32(lobby + G.PL_MEMBERS) or -1
    end

    -- Starts a capture whose baseline is the in-use table in buffer, or
    -- extends the running one.
    local function start(now, reason, buffer, slots)
        if capture then
            capture.last = now
            log(now, 'event: ' .. reason)
            return
        end
        capture = {started = now, last = now, frames = 0, based = slots > 0}
        base = decode(buffer, slots, base)
        members = lobby_members(cache.ctx)
        note(string.format('diag: capture start: %s; in-use entries %d; package queue head %d tail %d; unload pause %d; '
            .. 'lobby members %d', reason, size_of(base), head, tail, paused, members))
    end

    -- One captured frame: what changed since the last one.
    local function record(now, new_head, new_tail, new_paused, ctx)
        capture.frames = capture.frames + 1
        local parts = {}
        if new_tail ~= tail then parts[#parts + 1] = listed('queued', span(tail, new_tail)) end
        if new_head ~= head then parts[#parts + 1] = listed('processed', span(head, new_head)) end
        if new_paused ~= paused then parts[#parts + 1] = string.format('unload pause %d>%d', paused, new_paused) end
        local now_members = lobby_members(ctx)
        if now_members ~= members then
            parts[#parts + 1] = string.format('lobby members %d>%d', members, now_members)
            members = now_members
        end
        if #parts > 0 then capture.last = now end
        if now_slots == 0 then
            -- A failed copy compares nothing (it would read as every entry gone).
            parts[#parts + 1] = 'in-use table unreadable'
        elseif not capture.based then
            base, spare = decode(now_buf, now_slots, spare), base
            capture.based = true
            parts[#parts + 1] = 'in-use baseline taken now'
        else
            local current = decode(now_buf, now_slots, spare)
            local gone, changed, added = {}, {}, {}
            for key, count in pairs(base) do
                local c = current[key]
                if not c then
                    gone[#gone + 1] = string.format('%08x:%d', names[key] or 0, count)
                elseif c ~= count then
                    changed[#changed + 1] = string.format('%08x:%d>%d', names[key] or 0, count, c)
                end
            end
            for key, count in pairs(current) do
                if not base[key] then added[#added + 1] = string.format('%08x:%d', names[key] or 0, count) end
            end
            base, spare = current, base
            parts[#parts + 1] = listed('in-use gone', gone)
            parts[#parts + 1] = listed('changed', changed)
            parts[#parts + 1] = listed('new', added)
        end
        if #parts > 0 then log(now, table.concat(parts, '; ')) end
        if now - capture.last >= D.CAPTURE_AFTER or now - capture.started >= D.CAPTURE_MAX then
            note(string.format('diag: capture end after %d frames (%.1f s)', capture.frames, now - capture.started))
            capture = nil
        end
    end

    -- Players in the last frame's session who are gone now.
    local function departures(now)
        for i = 1, seen_n do
            local lo, hi = seen_lo[i], seen_hi[i]
            if not G.has_peer(snap, lo, hi) then
                local key = G.peer_key(lo, hi)
                if kicked[key] then
                    kicked[key] = nil
                    start(now, 'the kicked player ' .. api.u64_hex(lo, hi) .. ' left the session', last_buf, last_slots)
                else
                    start(now, 'player ' .. api.u64_hex(lo, hi) .. ' left the session (' .. history_text(lo, hi) .. ')',
                        last_buf, last_slots)
                end
            end
        end
    end

    local function remember(ctx)
        seen_n = 0
        if ctx == 0 then return end
        for i = 1, snap.peer_count do
            local peer = snap.peers[i]
            if not (peer.lo == snap.local_lo and peer.hi == snap.local_hi) then
                seen_n = seen_n + 1
                seen_lo[seen_n], seen_hi[seen_n] = peer.lo, peer.hi
            end
        end
    end

    -- First in the update, so every value is the frame's starting state.
    -- hosting_squad(): the addon's idle gate.
    -- A departure shows in the frame after it, when a two-player squad is
    -- already down to one: the frame after an armed frame is always recorded.
    function self.frame(now, hosting_squad)
        local watching = capture ~= nil or (armed and seen_n > 0)
        local ctx = 0
        if watching or hosting_squad() then
            ctx = G.context(api, game, cache)
            if ctx ~= 0 then G.read_session(api, game, ctx, snap) end
        end
        local squad = ctx ~= 0 and snap.is_host and snap.mode == G.MODE_SHIP and snap.peer_count >= 2
        if not watching and not squad then
            armed, seen_n = false, 0
            return
        end
        local new_head, new_tail, new_paused = sample()
        if armed and ctx ~= 0 then departures(now) end
        if capture then record(now, new_head, new_tail, new_paused, ctx) end
        head, tail, paused = new_head, new_tail, new_paused
        remember(ctx)
        armed = squad or capture ~= nil
    end

    -- how: 'kick' (kick_peer in the update), 'render' (kick_peer from the
    -- render callback) or 'message' (the kick message alone).
    function self.before_kick(lo, hi, now, how)
        kicked[G.peer_key(lo, hi)] = true
        start(now, 'mod ' .. (how or 'kick') .. ' of ' .. api.u64_hex(lo, hi), now_buf, now_slots)
        kick_tail = api.load32(pm + D.QUEUE_TAIL)
        log(now, string.format('before the %s: %s; package queue head %d tail %d; unload pause %d', how or 'kick',
            history_text(lo, hi), api.load32(pm + D.QUEUE_HEAD), kick_tail, api.load8(pm + D.UNLOAD_PAUSED)))
    end

    function self.after_kick(lo, hi, now, how)
        local new_tail = api.load32(pm + D.QUEUE_TAIL)
        local list = span(kick_tail, new_tail)
        log(now, string.format('after the %s: %s; queued during it %d%s', how or 'kick', history_text(lo, hi), #list,
            #list > 0 and (': ' .. table.concat(list, ', ')) or ''))
        if tail == kick_tail then tail = new_tail end
        capture.last = now
    end

    return self
end

return D
