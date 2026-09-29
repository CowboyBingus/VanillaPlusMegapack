-- Game layout for Better Lobby Management (Steam build 25480438): offsets, the code the
-- mod depends on, the native entry points it calls, and session readers.
-- Evidence and meaning of every value: docs/TECHNICAL.md.
local G = {}

-- game.dll globals
G.CONTEXT_PTR = 0x347cef0        -- network context: synchronizers, lobby, peers
G.GAME_STATE_PTR = 0x3326340     -- +MODE: 3 ship, 4 mission
G.ROSTER_PTR = 0x347ced8         -- 4 x 0xC0: peer id +0, persona name +8
G.ENGINE_API_PTR = 0x3326308     -- engine API tables; +0xF8 PlayFab lobby/browser
G.MATCHMAKING_PTR = 0x347ce80    -- matchmaking object (Galactic Map scanner, quickplay)
G.MODE = 0xac21c
G.MODE_SHIP, G.MODE_MISSION = 3, 4

-- network context offsets
G.SESSION, G.LOCAL, G.HOST = 0xb390, 0xb398, 0xb3a8
G.HOST_SYNC = 0x159b0            -- +24 hosting state (1 hosting), +28 transition step
G.HS_STATE, G.HS_TRANSITION = 24, 28
G.CLIENT_SYNC = 0x162c8          -- +1313 party join in progress (byte)
G.CS_PARTY_JOIN = 0x521
G.JOIN = 0x171c8                 -- join component; +0 state (0 idle)
G.LOBBY = 0x1d470                -- game lobby wrapper; +0 engine lobby
G.BROWSER = 0x1f028              -- engine lobby browser handle, shared by every game search
G.PEER_COUNT, G.PEERS, G.PEER_STRIDE, G.PEER_INDEX = 0x16390, 0x16398, 32, 20
G.MAX_PEERS = 4

-- engine lobby objects (helldivers2.exe layout)
G.ENGINE_LOBBY_PLAYFAB = 0x10    -- engine lobby -> PlayfabLobby
G.PL_STATE, G.PL_HANDLE = 0x118, 0x120
G.PL_MEMBERS = 0x100             -- PlayFab lobby member count (a kicked client leaves the lobby itself)
G.LOBBY_API = 0xf8
G.SLOT_CLEAR_FILTERS, G.SLOT_CONTINENT = 0x198, 0x40

-- matchmaking requests the mod must not overlap (state at +4; 1 = searching)
G.REQUESTS = {0x688, 0x56e0}     -- quickplay, Galactic Map scanner
G.REQUEST_SEARCHING = 1

-- Players are removed only through kick_peer (the game's kick: the kick message,
-- then remove_peer with reason Kicked); remove_peer itself is never called.
G.JOIN_PARTY, G.JOIN_REASON_QUICKPLAY = 2, 5
G.KEY_HOST_PEER = 3              -- logical lobby key 3 -> string_key2: host peer id in decimal
G.OP_EQUAL = 2

-- Native entry points: the start of each function must match.
G.NATIVES = {
    kick_peer = {rva = 0x108d130, type = 'LmKickPeer', bytes =
        '\72\137\92\36\8\87\72\131\236\32\72\139\218\72\139\249\76\139\194\72\141\13\46\99\29\1'},
    start_join = {rva = 0x108ff40, type = 'LmStartJoin', bytes =
        '\72\137\92\36\32\86\87\65\86\72\129\236\112\1\0\0\72\139\5\185\192\90\1'},
    filter_string = {rva = 0x1094df0, type = 'LmFilterString', bytes =
        '\64\85\86\87\72\131\236\80\72\139\5\17\114\90\1\72\51\196\72\137\68\36\48'},
    browser_start = {rva = 0x1094710, type = 'LmBrowserStart', bytes =
        '\76\139\17\77\133\210\116\100\72\139\5\33\39\41\2\128\120\9\0\116\28'},
    browser_busy = {rva = 0x1094780, type = 'LmBrowserBusy', bytes =
        '\72\131\236\40\76\139\1\77\133\192\117\7\50\192\72\131\196\40\195\72\139\5\166\38\41\2'},
    browser_count = {rva = 0x1094820, type = 'LmBrowserCount', bytes =
        '\76\139\1\77\133\192\117\3\51\192\195\72\139\5\14\38\41\2\128\120\9\0'},
    browser_result = {rva = 0x1094890, type = 'LmBrowserResult', bytes =
        '\64\85\86\87\65\87\72\129\236\56\2\0\0\72\139\5\108\119\90\1'},
    -- The kick message alone (the first half of kick_peer, without remove_peer).
    send_kick = {rva = 0xbf3950, type = 'LmSendKick', bytes =
        '\72\139\209\69\51\201\185\45\55\134\247\69\51\192\233\205\170\254\255'},
    is_friend = {rva = 0x13efea0, type = 'LmIsFriend', bytes =
        '\72\131\236\88\72\139\5\157\100\243\1\76\139\194\128\120\40\0\116\56'},
}

-- game.dll code that fixes the offsets above.
G.CODE = {
    -- Per-frame network update: host sync, client sync, lobby and join component offsets.
    {rva = 0x13f7858, name = 'network components', bytes =
        '\73\141\159\208\28\201\1\72\141\139\0\180\0\0\232\149\129\239\255\72\141\139\176\89\1\0\232\201'
        .. '\43\201\255\72\141\139\200\98\1\0\232\205\184\200\255\72\141\139\112\212\1\0\232\17\191\201\255'
        .. '\72\141\139\200\113\1\0'},
    -- Host-left handling: game mode offset, context global, event ring and host peer.
    {rva = 0x10834ed, name = 'host-left check', bytes =
        '\131\185\28\194\10\0\3\15\133\199\0\0\0\232\209\195\44\0\72\139\21\234\153\63\2\132\219\65\185\7'
        .. '\0\0\0\65\190\4\0\0\0\69\15\69\206\51\246\139\130\56\248\1\0\72\139\138\168\179\0\0'},
    -- Session peer list (count and 32-byte entries).
    {rva = 0x134fa90, name = 'peer list', bytes =
        '\72\137\92\36\16\86\72\131\236\32\51\219\72\139\241\57\153\144\99\1\0\118\119\72\137\124\36\48\15'
        .. '\31\64\0\139\195\72\193\224\5\72\139\188\48\152\99\1\0\72\59'},
    -- The two matchmaking requests and their state fields.
    {rva = 0x1337dcc, name = 'quickplay request', bytes = '\139\158\140\6\0\0\76\141\134\136\6\0\0'},
    {rva = 0x133812a, name = 'scanner request', bytes = '\139\158\228\86\0\0\76\141\134\224\86\0\0'},
    -- The lobby browser handle in the network context.
    {rva = 0x133d460, name = 'lobby browser', bytes =
        '\64\83\72\131\236\64\72\139\13\131\250\19\2\72\139\218\72\129\193\40\240\1\0\232'},
    -- The client synchronizer's party-join flag.
    {rva = 0x1082fe3, name = 'party join flag', bytes = '\72\141\131\48\13\0\0\198\131\33\5\0\0\1'},
}

-- helldivers2.exe code: the PlayfabLobby layout (PlayfabLobby::kick_member).
G.EXE_CODE = {
    {rva = 0x8cdf90, name = 'PlayFab lobby layout', bytes =
        '\72\139\70\24\139\207\72\139\12\200\72\139\89\16\72\99\131\24\1\0\0\131\248\3\15\133\81\1\0\0\73'
        .. '\139\214\72\141\13\216\173\221\0\232\35\55\207\255\72\139\139\32\1\0\0\72\141\148\36\208\0\0\0\76'
        .. '\137\188\36\208\0\0\0'},
    {rva = 0x8ce012, name = 'PlayFab lobby members', bytes = '\139\139\0\1\0\0\72\139\147\64\1\0\0'},
}

-- Engine lobby API slots the mod calls, checked through the pointer the table holds.
G.ENGINE_SLOTS = {
    clear_filters = {slot = 0x198, type = 'LmHandleCall', bytes = '\51\192\137\129\180\0\0\0\137\129\184\37\0\0\195'},
    continent = {slot = 0x40, type = 'LmSelfCall', bytes =
        '\72\139\5\161\132\169\1\72\139\136\208\5\0\0\51\192\72\139\137\160\0\0\0\72\133\201\116\10\72\131\193'
        .. '\68\56\1\72\15\69\193\195'},
}

-- Engine package API (the table game.dll releases packages through): the flag
-- that pauses package unloads, which the game sets while it tears a world
-- down. The mod holds it around its kicks (see lobby.lua).
G.PACKAGE_API = 0x10
G.PACKAGE_SLOTS = {
    unload_paused = {slot = 0x348, type = 'LmGetFlag', bytes =
        '\72\139\5\209\234\110\1\72\139\136\0\4\0\0\15\182\129\36\50\0\0\195'},
    pause_unloads = {slot = 0x350, type = 'LmSetFlag', bytes =
        '\72\139\5\177\234\110\1\133\201\15\149\194\72\139\136\0\4\0\0\136\145\36\50\0\0\195'},
}

G.PLAYFAB_DLL = 'PlayFabMultiplayerWin.dll' -- the test builds' recorder reads the lobby through it

-- Checks every signature and binds the natives. Returns natives or raises a
-- plain reason. exe: helldivers2.exe base.
function G.bind(api, game, exe)
    local function expect(condition, message) if not condition then error(message, 0) end end
    for _, code in ipairs(G.CODE) do
        expect(api.bytes(game + code.rva, #code.bytes) == code.bytes, code.name .. ' changed')
    end
    for _, code in ipairs(G.EXE_CODE) do
        expect(api.bytes(exe + code.rva, #code.bytes) == code.bytes, code.name .. ' changed')
    end
    local natives = {}
    for name, native in pairs(G.NATIVES) do
        expect(api.bytes(game + native.rva, #native.bytes) == native.bytes, name .. ' changed')
        natives[name] = api.native(native.type, game + native.rva)
    end
    local tables = api.load64(game + G.ENGINE_API_PTR)
    expect(tables ~= 0, 'engine API unavailable')
    local lobby_api = api.load64(tables + G.LOBBY_API)
    expect(lobby_api ~= 0, 'engine lobby API unavailable')
    natives.lobby_api = lobby_api
    for name, slot in pairs(G.ENGINE_SLOTS) do
        local address = api.load64(lobby_api + slot.slot)
        expect(address ~= 0 and api.bytes(address, #slot.bytes) == slot.bytes, 'engine ' .. name .. ' changed')
        natives[name] = api.native(slot.type, address)
    end
    local package_api = api.load64(tables + G.PACKAGE_API)
    expect(package_api ~= 0, 'engine package API unavailable')
    for name, slot in pairs(G.PACKAGE_SLOTS) do
        local address = api.load64(package_api + slot.slot)
        expect(address ~= 0 and api.bytes(address, #slot.bytes) == slot.bytes, 'engine ' .. name .. ' changed')
        natives[name] = api.native(slot.type, address)
    end
    return natives
end

-- A reusable session snapshot. read_session fills it with direct loads; the
-- context must have been confirmed readable once (see confirm_context).
function G.new_snapshot()
    local s = {peers = {}}
    for i = 1, G.MAX_PEERS do s.peers[i] = {lo = 0, hi = 0, index = 0} end
    return s
end

-- The context pointer, or 0. A new context (and the game state object) is
-- confirmed once with guarded reads; later frames use direct loads.
function G.context(api, game, cache)
    local ctx = api.load64(game + G.CONTEXT_PTR)
    if ctx == 0 then cache.ctx = 0; return 0 end
    if ctx ~= cache.ctx then
        local state = api.load64(game + G.GAME_STATE_PTR)
        if ctx % 8 ~= 0 or not api.read32(ctx + G.PEER_COUNT) or state == 0 or not api.read32(state + G.MODE) then
            cache.ctx = 0
            return 0
        end
        cache.ctx = ctx
    end
    return ctx
end

function G.read_session(api, game, ctx, s)
    s.ctx = ctx
    s.local_lo, s.local_hi = api.load32(ctx + G.LOCAL), api.load32(ctx + G.LOCAL + 4)
    s.host_lo, s.host_hi = api.load32(ctx + G.HOST), api.load32(ctx + G.HOST + 4)
    s.is_host = s.host_lo == s.local_lo and s.host_hi == s.local_hi
    local count = api.load32(ctx + G.PEER_COUNT)
    if count > G.MAX_PEERS then count = G.MAX_PEERS end
    s.peer_count = count
    for i = 1, count do
        local entry, peer = ctx + G.PEERS + (i - 1) * G.PEER_STRIDE, s.peers[i]
        peer.lo, peer.hi, peer.index = api.load32(entry), api.load32(entry + 4), api.load32(entry + G.PEER_INDEX)
    end
    local state = api.load64(game + G.GAME_STATE_PTR)
    s.mode = state ~= 0 and api.load32(state + G.MODE) or 0
    s.hosting = api.load32(ctx + G.HOST_SYNC + G.HS_STATE)
    s.transition = api.load32(ctx + G.HOST_SYNC + G.HS_TRANSITION)
    s.join_state = api.load32(ctx + G.JOIN)
    s.party_join = api.load8(ctx + G.CLIENT_SYNC + G.CS_PARTY_JOIN)
    return s
end

-- True when peer (lo, hi) is in the snapshot's session peer list.
function G.has_peer(s, lo, hi)
    for i = 1, s.peer_count do
        local peer = s.peers[i]
        if peer.lo == lo and peer.hi == hi then return true end
    end
    return false
end

-- Persona names by peer key (action frames only).
function G.peer_key(lo, hi) return string.format('%08X%08X', hi, lo) end
function G.names(api, game)
    local names, roster = {}, api.load64(game + G.ROSTER_PTR)
    if roster == 0 or not api.read32(roster) then return names end
    for slot = 0, 3 do
        local record = roster + slot * 0xc0
        local lo, hi = api.load32(record), api.load32(record + 4)
        if lo ~= 0 or hi ~= 0 then names[G.peer_key(lo, hi)] = api.cstring(record + 8, 0x78) end
    end
    return names
end

-- The PlayfabLobby object behind the game's lobby wrapper, or nil.
function G.playfab_lobby(api, ctx)
    local engine_lobby = api.read64(ctx + G.LOBBY)
    if not engine_lobby or engine_lobby == 0 then return nil end
    local lobby = api.read64(engine_lobby + G.ENGINE_LOBBY_PLAYFAB)
    if not lobby or lobby == 0 or not api.read32(lobby + G.PL_STATE) then return nil end
    return lobby
end

-- True while any game matchmaking request is searching (the mod then waits).
-- Action frames only: guarded reads.
function G.game_searching(api, game)
    local matchmaking = api.load64(game + G.MATCHMAKING_PTR)
    if matchmaking == 0 then return false end
    for _, request in ipairs(G.REQUESTS) do
        local state = api.read32(matchmaking + request + 4)
        if state == nil or state == G.REQUEST_SEARCHING then return true end
    end
    return false
end

return G
