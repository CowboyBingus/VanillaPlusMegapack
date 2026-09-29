-- Squad messages (src/chat.lua) against a simulated game chat: the text goes
-- through the game's own chat send with the network context's chat, reaching
-- every other session peer the host has not muted; nothing is sent while the
-- chat is off or nobody else is in the session; startup refuses on changed code.
-- Usage: test_chat.lua <src directory>
local source = assert(arg[1], 'source directory required')
local tests = (arg[0]:match('^(.*[/\\])') or './')
local budget = dofile(tests .. 'frame_budget.lua')
local Fake = dofile(tests .. 'fake_game.lua')
local G = dofile(source .. '/game.lua')
local C = dofile(source .. '/chat.lua')

local me, tango, echo = Fake.peer(0x0a1b2c3d, 0x4e5f6071), Fake.peer(0x9c8b7a69, 0x58473625), Fake.peer(0x0a000001, 7)

local function setup(configure)
    local world = Fake.new({G = G})
    Fake.install_chat(world, C, G)
    world.local_peer, world.host, world.session = me, me, {me, tango, echo}
    world.sync()
    if configure then configure(world) end
    local lines = {}
    local chat = C.new(world.api, Fake.GAME, G, function(line) lines[#lines + 1] = line end)
    return world, chat, lines
end

-- Startup refusals.
do
    local world, chat = setup(function(w) w.changed = Fake.GAME + C.SEND.rva end)
    local ok, why = chat.verify()
    assert(ok == false and why == 'chat send changed', why)
    world, chat = setup(function(w) w.changed = Fake.GAME + C.RPC.rva end)
    ok, why = chat.verify()
    assert(ok == false and why == 'RPC send changed', why)
    for _, code in ipairs(C.CODE) do
        world, chat = setup(function(w) w.changed = Fake.GAME + code.rva end)
        ok, why = chat.verify()
        assert(ok == false and why == code.name .. ' changed', why)
    end
end
print('PASS: squad messages refuse to start when the chat send, the RPC send or the code fixing either changed')

-- The new squad leader notice: the game's own rpc_from_host_notify_new_host, one u64, to every other peer.
do
    local world, chat, lines = setup()
    assert(chat.verify())
    local counts = budget.wrap(world.api)
    local frame, ok, n = budget.frame(counts, chat.new_leader, tango.lo, tango.hi)
    assert(ok == true and n == 2, tostring(n))
    budget.check(frame, {load32 = 9, load64 = 1, put32 = 2, u64 = 1}, 'squad leader notice')
    local sent = world.last('rpc_send')
    assert(sent[1] == C.NEW_HOST and sent[2] == 'FFFFFFFFFFFFFFFF' and sent[3] == 1, 'every other peer, one argument')
    assert(sent[4] == C.ARG_U64 and sent[5] == C.ARG_U64_SIZE and sent[6] == Fake.key(tango), 'the new leader\'s id')
    assert(world.count('chat_send') == 0 and #lines == 0, 'no chat line; quiet unless verbose')
    assert(chat.new_leader(echo.lo, echo.hi, true))
    assert(world.last('rpc_send')[6] == Fake.key(echo))
    assert(lines[1] == 'squad leader notice for 0A00000100000007 sent to 9C8B7A6958473625, 0A00000100000007', lines[1])
    -- Text chat off does not matter: it is not a chat line.
    world.chat.enabled = false
    world.chat.sync()
    assert(chat.new_leader(tango.lo, tango.hi))
    world.session = {me}
    world.sync()
    ok, n = chat.new_leader(tango.lo, tango.hi)
    assert(ok == false and n == 'nobody else in the session', n)
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    ok, n = chat.new_leader(tango.lo, tango.hi)
    assert(ok == false and n == 'no network session', n)
    assert(world.count('rpc_send') == 3, 'failures send nothing')
end
print('PASS: the new squad leader notice sends the game\'s own new-host RPC with the leader\'s peer id to every other '
    .. 'peer, with no page checks; no session or nobody else is reported')

-- One line through the game's chat send, as the chat box sends it.
do
    local world, chat, lines = setup()
    assert(chat.verify())
    local counts = budget.wrap(world.api)
    local frame, ok, n = budget.frame(counts, chat.send, 'Tango is the new host. The squad is moving to their ship.')
    assert(ok == true and n == 2, tostring(n))
    budget.check(frame, {load32 = 9, load64 = 1, put_string = 1, read32 = 1}, 'squad message')
    assert((frame.writable_data or 0) == 0, 'no page checks')
    local sent = world.last('chat_send')
    assert(sent[1] == Fake.CTX + C.CHAT and sent[2] == 0, 'the context\'s chat, as the chat box passes it')
    assert(sent[3] == 'Tango is the new host. The squad is moving to their ship.', sent[3])
    assert(world.count('chat_rpc') == 2 and world.calls[#world.calls][1] == Fake.key(echo), 'every other peer')
    assert(world.get32(Fake.CTX + C.CHAT + C.HISTORY_COUNT) == 1, 'the host\'s own chat shows it')
    assert(#lines == 0, 'quiet unless verbose')
    -- Verbose (diagnostic builds): the recipients and the host's chat history.
    assert(chat.send('hello', true))
    assert(lines[1] == 'squad message recipients: 9C8B7A6958473625, 0A00000100000007; your chat history 0/1 -> 0/2',
        lines[1])
    -- A muted peer is the game's business: the mod still reports the players in the session.
    world.chat.muted[Fake.key(tango)] = true
    local before = world.count('chat_rpc')
    ok, n = chat.send('x')
    assert(ok and n == 2 and world.count('chat_rpc') == before + 1)
end
print('PASS: a squad message goes through the game\'s chat send to every other peer, with no page checks')

-- Long text is cut to the game's limit without splitting a UTF-8 sequence.
do
    assert(C.cut('abc', 5) == 'abc' and C.cut('abcdef', 3) == 'abc')
    local text = ('x'):rep(510) .. '\226\130\172' .. 'yy' -- a 3-byte euro sign across byte 512
    assert(C.cut(text, 512) == ('x'):rep(510), 'the euro sign goes whole')
    local world, chat = setup()
    assert(chat.verify())
    assert(chat.send(text))
    assert(world.last('chat_send')[3] == ('x'):rep(510) and world.count('chat_rpc') == 2)
    assert(chat.send(('x'):rep(2000)))
    assert(#world.last('chat_send')[3] == C.MAX_TEXT)
end
print('PASS: long text is cut to 512 bytes on a UTF-8 boundary, so the game never drops it as invalid')

-- Failures come back as plain reasons and send nothing.
do
    local world, chat = setup()
    assert(chat.verify())
    world.chat.enabled = false
    world.chat.sync()
    local ok, why = chat.send('x')
    assert(ok == false and why == 'text chat is off', why)
    world.chat.enabled = true
    world.chat.sync()
    world.session = {me}
    world.sync()
    ok, why = chat.send('x')
    assert(ok == false and why == 'nobody else in the session', why)
    world.session = {me, tango}
    world.sync()
    world.unmapped[Fake.CTX + C.CHAT] = true
    ok, why = chat.send('x')
    assert(ok == false and why == 'the chat is unreadable', why)
    world.unmapped[Fake.CTX + C.CHAT] = nil
    world.put64(Fake.GAME + G.CONTEXT_PTR, 0)
    ok, why = chat.send('x')
    assert(ok == false and why == 'no network session', why)
    assert(world.count('chat_send') == 0, 'nothing sent')
end
print('PASS: chat off, nobody else in the session, an unreadable chat and no session are reported, never raised')
