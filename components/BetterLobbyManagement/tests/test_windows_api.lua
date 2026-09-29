-- The Windows and native-call layer in the game's own LuaJIT (run through
-- run_game_lua.py): loads, guarded reads, page checks, checked writes, C
-- strings, the aligned scratch block, 64-bit peer ids through the native
-- pointer types, module hashing and zero garbage; then the whole update hook
-- and the region check on real memory, with garbage, compiled code and time
-- measured.
-- Usage: test_windows_api.lua <src directory> [SHA-256 of the loaded lua51.dll]
local source = assert(arg[1], 'source directory required')
local lua51_sha256 = arg[2]
local ffi = require('ffi')
local create_api = dofile(source .. '/windows_api.lua')
local G = dofile(source .. '/game.lua')
local L = dofile(source .. '/lobby.lua')
local R = dofile(source .. '/region.lua')
local M = dofile(source .. '/menu.lua')
local C = dofile(source .. '/chat.lua')
local S = dofile(source .. '/scanner.lua')
local api = create_api()
assert(create_api() ~= api, 'each call builds its own api') -- repeated setup must not fail
local function address(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end

-- Loads and guarded reads on memory this test owns.
local block = ffi.new('uint32_t[16]')
local a = address(block)
block[0], block[1], block[2] = 0xbe929838, 0x1be, 20
assert(api.load8(a) == 0x38 and api.load32(a) == 0xbe929838 and api.load32(a + 8) == 20)
assert(api.load64(a) == 0x1bebe929838)
assert(api.read32(a + 8) == 20 and api.read64(a) == 0x1bebe929838)
assert(api.read32(16) == nil and api.read64(16) == nil, 'unmapped reads fail without faulting')
assert(api.bytes(a, 8) == ffi.string(block, 8))
-- Block reads (diagnostic builds): one guarded copy into a reused buffer.
local copy = api.buffer(64)
assert(api.read_block(a, copy, 64) and api.load32(copy) == 0xbe929838 and api.load64(copy) == 0x1bebe929838)
assert(api.read_block(16, copy, 64) == false, 'an unmapped block read fails without faulting')
assert(api.load32(copy + 8) == 20, 'a failed block read leaves the buffer')

-- Page checks: private read/write memory yes; module images, free memory and
-- ranges past the region end no.
local queries = api.queries
local code = address(ffi.cast('void *', ffi.load('kernel32').GetCurrentProcess))
assert(api.writable_data(a, 64) == true)
assert(api.writable_data(code, 4) == false, 'module image is not writable data')
assert(api.writable_data(16, 4) == false, 'free memory is not writable data')
assert(api.writable_data(a, 2 ^ 40) == false, 'a range past the region end is refused')
assert(api.queries == queries + 4)
queries = api.queries

-- Writes: one page check per call, then direct stores.
assert(api.write32(a + 8, 1) and block[2] == 1)
assert(api.write_words(a, 64, {12, 0xdeadbeef, 16, 7, 0, 5}) and block[3] == 0xdeadbeef and block[4] == 7
    and block[0] == 5)
local original = api.load32(code)
assert(api.write32(code, 0) == false and api.write_words(code, 4, {0, 0}) == false and api.load32(code) == original)
assert(api.queries == queries + 4, 'one page check per write call')
-- Floats (the scanner's countdown): a guarded read, and a checked write.
assert(api.write_f32(a + 20, 12.5) and api.read_f32(a + 20) == 12.5 and api.loadf(a + 20) == 12.5)
assert(api.read_f32(16) == nil, 'an unmapped float read fails without faulting')
assert(api.write_f32(code, 1) == false and api.load32(code) == original)
assert(api.queries == queries + 6)

-- C strings, the scratch block and stores.
local text = ffi.new('char[16]', 'Tango')
assert(api.cstring(address(text), 64) == 'Tango' and api.cstring(address(text), 3) == 'Tan')
assert(api.cstring(0, 8) == nil)
assert(api.scratch % 16 == 0 and api.SCRATCH_SIZE == 1024, 'scratch is 16-byte aligned')
api.put_string(api.scratch, 'title_player_account', 32)
assert(api.cstring(api.scratch, 32) == 'title_player_account')
assert(not pcall(api.put_string, api.scratch, ('x'):rep(32), 32), 'a string leaves room for its terminator')
api.put64(api.scratch + 32, 0x12345678abcd)
assert(api.load64(api.scratch + 32) == 0x12345678abcd)
api.zero(api.scratch, 48)
assert(api.load64(api.scratch) == 0 and api.load64(api.scratch + 32) == 0)

-- Peer ids are above 2^53: halves, decimal (lobby search) and hex (logs).
local lo, hi = 0x4e5f6071, 0x0a1b2c3d -- a peer id beyond 2^53
assert(api.u64_decimal(lo, hi) == '728224406569967729' and api.u64_hex(lo, hi) == 'A1B2C3D4E5F6071')
assert(api.u64_hex(0x1f, 0) == '1F' and api.u64_hex(5, 1) == '100000005')
assert(api.u64_decimal(0xffffffff, 0xffffffff) == '18446744073709551615')
assert(api.u64_decimal(0, 0) == '0' and api.u64_decimal(999999, 0) == '999999' and api.u64_decimal(1000000, 0) == '1000000')
assert(api.u64_decimal(0x5e6f7081, 0x1a2b3c4d) == '1885667171979194497', 'a lobby handle beyond 2^53')
-- The game replaces tostring (64-bit cdata print as '[cdata (deleted)]'); decimals must not depend on it.
do
    local saved = tostring
    tostring = function() return '[cdata (deleted)]' end
    local ok, value = pcall(api.u64_decimal, lo, hi)
    tostring = saved
    assert(ok and value == '728224406569967729', 'u64_decimal without tostring: ' .. tostring(value))
end
assert(api.u64(lo, hi) == 728224406569967729ULL)

-- Every pointer type the game layout names exists; values reach native code intact.
for _, native in pairs(G.NATIVES) do assert(pcall(ffi.typeof, native.type), native.type) end
for _, slot in pairs(G.ENGINE_SLOTS) do assert(pcall(ffi.typeof, slot.type), slot.type) end
for _, slot in pairs(G.PACKAGE_SLOTS) do assert(pcall(ffi.typeof, slot.type), slot.type) end
for _, native in ipairs({C.SEND, C.RPC}) do assert(pcall(ffi.typeof, native.type), native.type) end
for _, native in pairs(M.NATIVES) do assert(pcall(ffi.typeof, native.type), native.type) end
local got = {}
local on_kick = ffi.cast('LmKickPeer', function(host_sync, peer)
    got.host_sync, got.peer = host_sync, peer
end)
local on_text = ffi.cast('LmSetStringArg', function(widget, key, text)
    got.widget, got.key, got.text = widget, key, ffi.string(ffi.cast('const char *', text))
end)
local on_dialog = ffi.cast('LmDialogSetup', function(dialog, title, text, confirm, cancel, hold, flag)
    got.dialog = {tonumber(dialog), title, text, confirm, cancel, hold, flag}
    return 0
end)
local on_rpc = ffi.cast('LmRpcSend', function(hash, target, args, count)
    got.hash, got.target, got.args, got.count = hash, target, args, count
end)
local on_join = ffi.cast('LmStartJoin', function(join, info, kind, unused, reason)
    got.kind, got.reason_join = kind, reason
    return 1
end)
jit.off()
api.native('LmKickPeer', address(on_kick))(0x20000000000 + G.HOST_SYNC, api.u64(lo, hi))
local text = ffi.new('char[8]', 'PROMOTE')
api.native('LmSetStringArg', address(on_text))(0x30000000000, M.TEXT_KEY, address(text))
api.native('LmDialogSetup', address(on_dialog))(0x30000000010, M.TEXT_TEMPLATE, M.TEXT_TEMPLATE, M.CONFIRM_LABEL,
    M.CANCEL_LABEL, 1, 0)
api.native('LmRpcSend', address(on_rpc))(C.NEW_HOST, api.u64(C.EVERY_PEER, C.EVERY_PEER), api.scratch, 1)
local joined = api.native('LmStartJoin', address(on_join))(0x20000000000 + G.JOIN, api.scratch, G.JOIN_PARTY, 0,
    G.JOIN_REASON_QUICKPLAY)
jit.on()
on_kick:free(); on_rpc:free(); on_join:free(); on_text:free(); on_dialog:free()
assert(got.peer == api.u64(lo, hi) and tonumber(got.host_sync) == 0x20000000000 + G.HOST_SYNC)
assert(tonumber(got.widget) == 0x30000000000 and got.key == M.TEXT_KEY and got.text == 'PROMOTE')
assert(got.dialog[1] == 0x30000000010 and got.dialog[2] == M.TEXT_TEMPLATE and got.dialog[4] == M.CONFIRM_LABEL
    and got.dialog[5] == M.CANCEL_LABEL and got.dialog[6] == 1 and got.dialog[7] == 0)
assert(got.hash == C.NEW_HOST and got.target == 0xffffffffffffffffULL and tonumber(got.args) == api.scratch
    and got.count == 1, 'a hash above 2^31 and the target -1 reach the RPC send intact')
assert(joined == 1 and got.kind == 2 and got.reason_join == 5)

-- Modules and hashes.
assert(type(api.module(nil)) == 'number' and type(api.module('kernel32.dll')) == 'number')
assert(api.module('game.dll') == nil, 'the game is not loaded in a test process')
assert(api.export(api.module('kernel32.dll'), 'GetCurrentProcess') == code)
assert(api.export(api.module('kernel32.dll'), 'NoSuchExport') == nil)
local lua51 = assert(api.module('lua51.dll'), 'run inside the game lua51.dll')
local digest = api.module_sha256(lua51)
assert(#digest == 64 and digest:match('^[0-9A-F]+$'))
if lua51_sha256 then assert(digest == lua51_sha256:upper(), 'module hash mismatch') end
print('PASS: loads, guarded reads, page checks (private data only), checked writes, C strings, aligned scratch, '
    .. '64-bit peer ids through the native pointer types, module lookup, exports and SHA-256')

-- Garbage: the per-frame primitives allocate nothing. The loop runs once to
-- compile first: the JIT's own trace objects live in the same heap.
local function primitives(n)
    for _ = 1, n do api.load8(a); api.load32(a); api.load64(a); api.read32(a + 8); api.read64(a) end
end
primitives(20000)
collectgarbage('collect'); collectgarbage('stop')
local before = collectgarbage('count')
primitives(100000)
local used = collectgarbage('count') - before
collectgarbage('restart')
assert(used < 1, 'primitives allocated ' .. used .. ' KB')
print(string.format('PASS: 100,000 x (3 loads + 2 guarded reads) allocated %.3f KB', used))

-- A game on real memory: a zeroed game.dll image with the verified code in
-- place, a helldivers2.exe image, the engine lobby API table, the network
-- context, the game state and the override config.
local image = ffi.new('uint8_t[?]', 0x3480000)
local game = address(image)
local exe_image = ffi.new('uint8_t[?]', 0x8f0000)
local exe = address(exe_image)
local function place(base, rva, bytes) ffi.copy(ffi.cast('uint8_t *', base + rva), bytes, #bytes) end
for _, check in ipairs(G.CODE) do place(game, check.rva, check.bytes) end
for _, native in pairs(G.NATIVES) do place(game, native.rva, native.bytes) end
for _, check in ipairs(R.CODE) do place(game, check.rva, check.bytes) end
for _, check in ipairs(M.CODE) do place(game, check.rva, check.bytes) end
for _, native in pairs(M.NATIVES) do place(game, native.rva, native.bytes) end
for _, check in ipairs(G.EXE_CODE) do place(exe, check.rva, check.bytes) end
for _, check in ipairs(C.CODE) do place(game, check.rva, check.bytes) end
place(game, C.SEND.rva, C.SEND.bytes)
place(game, C.RPC.rva, C.RPC.bytes)
for _, check in ipairs(S.CODE) do place(game, check.rva, check.bytes) end
local function object(size) local o = ffi.new('uint8_t[?]', size + 16); return o, math.ceil(address(o) / 16) * 16 end
local tables_block, tables = object(0x200)
local lobby_block, lobby_api = object(0x200)
local slots = {}
ffi.cast('uint64_t *', game + G.ENGINE_API_PTR)[0] = tables
ffi.cast('uint64_t *', tables + G.LOBBY_API)[0] = lobby_api
for name, slot in pairs(G.ENGINE_SLOTS) do
    local holder, at = object(64)
    slots[name] = holder
    place(at, 0, slot.bytes)
    ffi.cast('uint64_t *', lobby_api + slot.slot)[0] = at
end
local package_block, package_api = object(0x400)
ffi.cast('uint64_t *', tables + G.PACKAGE_API)[0] = package_api
for name, slot in pairs(G.PACKAGE_SLOTS) do
    local holder, at = object(64)
    slots[name] = holder
    place(at, 0, slot.bytes)
    ffi.cast('uint64_t *', package_api + slot.slot)[0] = at
end
local playfab_block, playfab = object(64)
local ctx_block, ctx = object(0x20000)
local state_block, state = object(G.MODE + 16)
local roster_block, roster = object(4 * 0xc0)
ffi.cast('uint64_t *', game + G.GAME_STATE_PTR)[0] = state
ffi.cast('uint64_t *', game + G.ROSTER_PTR)[0] = roster
ffi.cast('uint32_t *', state + G.MODE)[0] = G.MODE_SHIP
for index, continent in ipairs(R.CONTINENTS) do
    ffi.cast('uint32_t *', game + R.CONTINENT_IDS_RVA)[index - 1] = continent[2]
end
local function set_peers(list, local_peer, host)
    local words = ffi.cast('uint32_t *', ctx)
    words[G.PEER_COUNT / 4] = #list
    for i, peer in ipairs(list) do
        local entry = (G.PEERS + (i - 1) * G.PEER_STRIDE) / 4
        words[entry], words[entry + 1], words[entry + G.PEER_INDEX / 4] = peer[1], peer[2], i - 1
    end
    words[G.LOCAL / 4], words[G.LOCAL / 4 + 1] = local_peer[1], local_peer[2]
    words[G.HOST / 4], words[G.HOST / 4 + 1] = host[1], host[2]
    words[(G.HOST_SYNC + G.HS_STATE) / 4] = 1
end

-- The update hook (src/addon.lua) on this layer; only the module identities
-- are faked, every memory access and verification is real.
local installed = setmetatable({}, {__index = _G})
installed._G = installed
installed.update = function(dt) return dt end
installed.CowboyBingusModLoader = {open_log = function() return {write = function() end, flush = function() end} end}
-- The menu system with the escape menu closed (no screen): the natives are never called here.
local menu_block, menu_system = object(0x100)
ffi.cast('uint64_t *', game + M.MENU_SYSTEM_PTR)[0] = menu_system
local addon_api = setmetatable({}, {__index = api})
addon_api.module = function(name)
    if name == 'game.dll' then return game elseif name == G.PLAYFAB_DLL then return playfab end
    return exe
end
addon_api.module_sha256 = function(module) return module == game and 'G' or 'E' end
addon_api.export = function(module, name) return module == playfab and playfab + #name or nil end
local installer = setfenv(assert(loadfile(source .. '/addon.lua')), installed)()
installer(function() return addon_api end, G, L, R, M, C, S, {version = 'test', game_sha256 = 'G', exe_sha256 = 'E'})
local mod = installed.BetterLobbyManagement
assert(mod.status == 'ready', mod.status)
local update = installed.update
update(0.016)
assert(mod.menu == 'ready' and mod.options == 'not installed (defaults in use)', mod.menu)

-- Measures n update hooks: garbage (interpreted and compiled), machine code and time.
local util = require('jit.util')
local function measure(label, n)
    local traces = {}
    local function on_trace(what, trace) if what == 'stop' then traces[#traces + 1] = trace end end
    local function hooks(count) for _ = 1, count do update(0.016) end end
    jit.flush()
    jit.attach(on_trace, 'trace')
    hooks(20000)
    collectgarbage('collect'); collectgarbage('stop')
    local start_kb, t0 = collectgarbage('count'), os.clock()
    hooks(n)
    local elapsed, garbage = os.clock() - t0, collectgarbage('count') - start_kb
    collectgarbage('restart')
    jit.attach(on_trace)
    local mcode = 0
    for _, trace in ipairs(traces) do
        local machine = util.tracemc(trace)
        if machine then mcode = mcode + #machine end
    end
    jit.off(); jit.flush()
    collectgarbage('collect'); collectgarbage('stop')
    start_kb = collectgarbage('count')
    local t1 = os.clock()
    hooks(50000)
    local interpreted, interpreted_garbage = os.clock() - t1, collectgarbage('count') - start_kb
    collectgarbage('restart')
    jit.on()
    assert(garbage < 1 and interpreted_garbage < 0.5,
        string.format('%s allocated %.3f KB compiled, %.3f KB interpreted', label, garbage, interpreted_garbage))
    print(string.format('INFO: %s: %d traces / %d bytes of machine code, %.4f us/hook compiled, %.3f us '
        .. 'interpreted, garbage %.3f KB / %.3f KB', label, #traces, mcode, elapsed / n * 1e6,
        interpreted / 50000 * 1e6, garbage, interpreted_garbage))
    return mcode
end

local me, other = {lo, hi}, {0x2a1b3c4d, 0x0a000001}
queries = api.queries
local mcode_title = measure('idle hook, no session (title screen)', 2000000)
ffi.cast('uint64_t *', game + G.CONTEXT_PTR)[0] = ctx
set_peers({me}, me, me)
local mcode_alone = measure('idle hook, alone on the ship', 2000000)
set_peers({other, me}, me, other)
local mcode_client = measure('idle hook, in another host\'s squad', 2000000)
set_peers({me, other}, me, me)
local mcode_host = measure('idle hook, hosting a squad, escape menu closed', 2000000)
assert(api.queries == queries, 'idle hooks never check pages')
-- Since v1.0 every idle hook includes the Galactic Map scanner's check (formerly the standalone Fast Lobby
-- Scanner, 1.1 KB in 2 traces of its own), and trace formation varies between runs: the title-screen hook
-- measured 2.6 to 5.0 KB, so its guard is 8 KB like the other idle paths (was 4 KB).
assert(mcode_title < 8192 and mcode_alone < 8192 and mcode_client < 8192 and mcode_host < 16384,
    'idle hook machine code grew')
print('PASS: the update hook on real memory: no session, alone, as a client and hosting a squad with the escape menu '
    .. 'closed: no page checks, no garbage (interpreted or compiled)')

-- The region check on real memory: a config object laid out like the game's,
-- the server's 16 pairs, own continent NA; the flags are written once, then
-- every check is loads only and allocates nothing. The object gets a
-- committed region of its own, as the game's heap object has: an FFI
-- allocation can straddle two regions, and the mod's page check then
-- (rightly) refuses the write.
pcall(ffi.cdef, 'void *VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect);')
local config = address(ffi.load('kernel32').VirtualAlloc(nil, 0x1b000, 0x3000, 4))
assert(config ~= 0, 'test config region')
ffi.cast('uint64_t *', game + R.CONFIG_PTR)[0] = config
local function words_at(at) return ffi.cast('uint32_t *', at) end
for _, offset in ipairs({R.TABLE, R.SYNCED_TABLE}) do
    local header = config + offset
    ffi.cast('uint64_t *', header)[0] = header + R.ENTRIES
    words_at(header)[2], words_at(header)[3], words_at(header)[4] = R.CAPACITY, 0, 2
end
local function insert(header, key, value)
    local start = R.mul32(key, 2)
    for i = 0, R.CAPACITY - 1 do
        local entry = words_at(header + R.ENTRIES + ((start + i) % R.CAPACITY) * R.ENTRY_SIZE)
        if entry[0] == 0 then
            entry[0], entry[4], entry[5], entry[6] = key, key, R.TYPE_BOOL, value
            words_at(header)[R.COUNT / 4] = words_at(header)[R.COUNT / 4] + 1
            return
        end
    end
end
local main = config + R.TABLE
for own_index, row in ipairs(R.ROWS) do
    for _, entry in ipairs(row) do
        -- The server's live matrix: the 16 disallowed pairs.
        local disallowed = {AF = 'NA OC SA', AS = 'NA SA', EU = 'SA', NA = 'AF AS OC', OC = 'AF NA SA',
                            SA = 'AF AS EU OC'}
        if (disallowed[row.name] or ''):find(entry.name) then insert(main, entry.key, 0) end
    end
end
words_at(main)[R.CHECKSUM / 4] = 0x6699f3e5
local continent_text = ffi.new('char[4]', 'NA')
local region_status = {}
local region = R.new(api, game, {continent = function() return address(continent_text) end, lobby_api = 0},
    region_status, function() end)
assert(region.verify())
queries = api.queries
assert(region.set_mode(2) and region_status.region == 'my continent only (NA)')
assert(api.queries == queries + 1, 'one page check for the whole write')
local traces = {}
local function on_trace(what, trace) if what == 'stop' then traces[#traces + 1] = trace end end
local function checks(frames) for _ = 1, frames do region.step() end end
jit.flush()
jit.attach(on_trace, 'trace')
checks(R.VERIFY_FRAMES * 200)
local CHECKS = 20000
collectgarbage('collect'); collectgarbage('stop')
before = collectgarbage('count')
local t0 = os.clock()
checks(R.VERIFY_FRAMES * CHECKS)
local elapsed = os.clock() - t0
used = collectgarbage('count') - before
collectgarbage('restart')
jit.attach(on_trace)
local region_mcode = 0
for _, trace in ipairs(traces) do
    local machine = util.tracemc(trace)
    if machine then region_mcode = region_mcode + #machine end
end
assert(used < 1, 'region checks allocated ' .. used .. ' KB')
assert(api.queries == queries + 1, 'checks with the flags in place never check pages')
assert(region.restore() == 3 and region_status.region == 'game default')
print(string.format('PASS: region on real memory: one page check to write, then %d checks (one per %d frames) '
    .. 'allocated %.3f KB, %.3f us per frame averaged, %d traces / %d bytes of machine code', CHECKS,
    R.VERIFY_FRAMES, used, elapsed / (R.VERIFY_FRAMES * CHECKS) * 1e6, #traces, region_mcode))
