-- Squad messages, two kinds, action frames only:
--
-- A chat line: one line of the game's own text chat, sent the way the chat box
-- sends what the host types. The chat box (game.dll 0x186025D) hands the
-- network context's chat (ctx + 0xC418) and the typed text to 0x1097560, which
-- packs the UTF-8 text into rpc_ingame_chat_message (0x9FDDB88E, one u32
-- array), sends it to every other peer the host has not muted and shows it in
-- the host's own chat. The message has no sender or type field: every client,
-- with or without the mod, shows it as "<host>: text". (The game sends no chat
-- through PlayFab Party; v0.4-diag6's Party text reached nobody.)
--
-- The new squad leader notice (test builds): rpc_from_host_notify_new_host
-- (0xB9E77C36, one u64 peer id), which a host that took over after a mission
-- migration sends to every peer (game.dll 0x108A2DC). A client accepts it only
-- from its current host (0xB925A0); it then shows the new leader in its HUD and
-- adds event 5 {peer} to the session's event ring, from which the chat shows
-- "<name> is the new squad leader" (no colon). Other clients also send the
-- named peer their migration state (RPC 0xE15F07B2 per tracked object), so it
-- is tested with one friend first.
local C = {}

C.CHAT = 0xc418                -- network context -> the game's text chat; +0 enabled (byte)
C.SEND = {rva = 0x1097560, type = 'LmChatSend', bytes =
    '\65\86\65\87\72\129\236\120\4\0\0\72\139\5\158\74\90\1\72\51\196\72\137\132\36\80\4\0\0\128\57\0'}
-- The game's RPC send: (hash, target peer or -1 for every other peer, arguments, count).
C.RPC = {rva = 0xbde430, type = 'LmRpcSend', bytes =
    '\64\83\85\86\87\65\86\65\87\72\129\236\152\0\0\0\72\139\5\201\219\165\1\72\51\196\72\137'}
C.CODE = {
    -- The chat box hands the context's chat and the typed text to the send.
    {rva = 0x186025d, name = 'chat box send', bytes =
        '\72\139\13\140\204\193\1\76\141\135\212\22\0\0\72\129\193\24\196\0\0\232\233\114\131\255'},
    -- The send's message: rpc_ingame_chat_message with one argument.
    {rva = 0xbeb103, name = 'chat message RPC', bytes = '\65\185\1\0\0\0\72\139\215\185\142\184\221\159\232\26\51\255\255'},
    -- The chat's 64-line history (first line, line count), read by diagnostic builds.
    {rva = 0x1097a7c, name = 'chat history', bytes = '\139\135\148\149\0\0\139\143\144\149\0\0'},
    -- The game's own new-host notice: one argument of type 9 (8 bytes), to every peer (-1).
    {rva = 0x108a2dc, name = 'new host notice', bytes =
        '\72\141\69\103\72\137\93\103\65\185\1\0\0\0\72\137\69\231\76\141\69\223\199\69\223\9\0\0\0\72\199\194'
        .. '\255\255\255\255\199\69\227\8\0\0\0\185\54\124\231\185\232\31\65\181\255'},
}
C.HISTORY_FIRST, C.HISTORY_COUNT = 0x9590, 0x9594
C.MAX_TEXT = 512               -- the game sends at most 512 bytes and drops a line that is not valid UTF-8
C.NEW_HOST = 0xb9e77c36        -- rpc_from_host_notify_new_host
C.ARG_U64, C.ARG_U64_SIZE = 9, 8
C.EVERY_PEER = 0xffffffff      -- both halves of the target -1
-- One RPC argument: {u32 type, u32 size, u64 address of the value}; the value follows.
C.ARGS_SIZE, C.ARG_VALUE = 24, 16

-- text cut to at most max bytes without splitting a UTF-8 sequence.
function C.cut(text, max)
    if #text <= max then return text end
    local n = max
    while n > 0 and text:byte(n + 1) >= 0x80 and text:byte(n + 1) < 0xc0 do n = n - 1 end
    return text:sub(1, n)
end

-- game: the game.dll base. G: src/game.lua. note(message): the mod's log.
function C.new(api, game, G, note)
    local self = {}
    local send, rpc, text_buffer, args

    -- Once: the natives and the code that fixes the chat's place and the messages.
    function self.verify()
        if api.bytes(game + C.SEND.rva, #C.SEND.bytes) ~= C.SEND.bytes then return false, 'chat send changed' end
        if api.bytes(game + C.RPC.rva, #C.RPC.bytes) ~= C.RPC.bytes then return false, 'RPC send changed' end
        for _, code in ipairs(C.CODE) do
            if api.bytes(game + code.rva, #code.bytes) ~= code.bytes then return false, code.name .. ' changed' end
        end
        send = api.native(C.SEND.type, game + C.SEND.rva)
        rpc = api.native(C.RPC.type, game + C.RPC.rva)
        text_buffer = api.buffer(C.MAX_TEXT + 1)
        args = api.buffer(C.ARGS_SIZE)
        api.put32(args, C.ARG_U64)
        api.put32(args + 4, C.ARG_U64_SIZE)
        api.put64(args + 8, args + C.ARG_VALUE)
        return true
    end

    local function history(chat)
        return api.load32(chat + C.HISTORY_FIRST) .. '/' .. api.load32(chat + C.HISTORY_COUNT)
    end

    -- The other players in the session: their count and, if verbose, their peer ids.
    local function others(ctx, verbose)
        local own_lo, own_hi = api.load32(ctx + G.LOCAL), api.load32(ctx + G.LOCAL + 4)
        local count, n, ids = math.min(api.load32(ctx + G.PEER_COUNT), G.MAX_PEERS), 0, verbose and {}
        for i = 0, count - 1 do
            local entry = ctx + G.PEERS + i * G.PEER_STRIDE
            local lo, hi = api.load32(entry), api.load32(entry + 4)
            if lo ~= own_lo or hi ~= own_hi then
                n = n + 1
                if ids then ids[#ids + 1] = string.format('%08X%08X', hi, lo) end
            end
        end
        return n, ids and table.concat(ids, ', ')
    end

    -- Sends text as the host's chat line. Returns true and the number of other
    -- players in the session, or false and why. verbose (diagnostic builds)
    -- logs the recipients' peer ids and the host's chat history before and
    -- after (a changed history means the game ran the whole send).
    function self.send(text, verbose)
        local ctx = api.load64(game + G.CONTEXT_PTR)
        if ctx == 0 then return false, 'no network session' end
        local chat = ctx + C.CHAT
        local enabled = api.read32(chat)
        if not enabled then return false, 'the chat is unreadable' end
        if enabled % 256 == 0 then return false, 'text chat is off' end
        local n, ids = others(ctx, verbose)
        if n == 0 then return false, 'nobody else in the session' end
        api.put_string(text_buffer, C.cut(text, C.MAX_TEXT), C.MAX_TEXT + 1)
        local before = verbose and history(chat)
        send(chat, 0, text_buffer)
        if verbose then
            note('squad message recipients: ' .. ids .. '; your chat history ' .. before .. ' -> ' .. history(chat))
        end
        return true, n
    end

    -- Tells every other player that the peer lo/hi is the new squad leader, as
    -- the game's own notice does. Returns true and the number of other players,
    -- or false and why. verbose (diagnostic builds) logs the recipients.
    function self.new_leader(lo, hi, verbose)
        local ctx = api.load64(game + G.CONTEXT_PTR)
        if ctx == 0 then return false, 'no network session' end
        local n, ids = others(ctx, verbose)
        if n == 0 then return false, 'nobody else in the session' end
        api.put32(args + C.ARG_VALUE, lo)
        api.put32(args + C.ARG_VALUE + 4, hi)
        rpc(C.NEW_HOST, api.u64(C.EVERY_PEER, C.EVERY_PEER), args, 1)
        if verbose then note(string.format('squad leader notice for %08X%08X sent to %s', hi, lo, ids)) end
        return true, n
    end

    return self
end

return C
