-- A simulated game for Better Lobby Management tests: sparse byte memory behind a fake
-- api (same functions as src/windows_api.lua), the network context, lobby
-- browser, PlayFab lobby and override tables, and fake natives whose effects
-- the scenario controls. Usage: local Fake = dofile(tests .. 'fake_game.lua')
local ffi = require('ffi')
local F = {}

F.GAME, F.EXE, F.PLAYFAB = 0x7ff600000000, 0x7ff700000000, 0x7ff800000000
F.CTX, F.STATE, F.ROSTER, F.MATCH = 0x20000000000, 0x21000000000, 0x22000000000, 0x23000000000
F.ENGINE_LOBBY, F.PLAYFAB_LOBBY = 0x24000000000, 0x24000010000
F.TABLES, F.LOBBY_API, F.CONFIG = 0x25000000000, 0x25000010000, 0x26000000000
F.SCRATCH, F.CONTINENT_TEXT, F.STRINGS = 0x29000000000, 0x2a000000000, 0x2b000000000
F.PACKAGE_API, F.BUFFERS = 0x25000020000, 0x2d000000000

-- The server's continent matrix read from the running game (build 25480438):
-- the 16 disallowed pairs with their keys, the row keys, the table checksum.
F.LIVE_PAIRS = {{'AF', 'NA', 0xab51eec3}, {'AF', 'OC', 0x80d2f030}, {'AF', 'SA', 0xb054a52d},
                {'AS', 'NA', 0xb68b9196}, {'AS', 'SA', 0xad8eda78}, {'EU', 'SA', 0x42d3342d},
                {'NA', 'AF', 0xfcc740c3}, {'NA', 'AS', 0x506e91a2}, {'NA', 'OC', 0x99f152f0},
                {'OC', 'AF', 0xa3b874fc}, {'OC', 'NA', 0xed0d783c}, {'OC', 'SA', 0xf60833d2},
                {'SA', 'AF', 0x2744b955}, {'SA', 'AS', 0x8bed6834}, {'SA', 'EU', 0x8cd6ca55},
                {'SA', 'OC', 0x4272ab66}}
F.ROW_KEYS = {AF = 0xf2594cb8, AS = 0x5ef09dd9, EU = 0x59cb3fb8, NA = 0xbcec4078, OC = 0x976f5e8b, SA = 0xa7e90b96}
F.SERVER_CHECKSUM = 0x6699f3e5

local function u64_parts(value) return value % 4294967296, (value - value % 4294967296) / 4294967296 end
function F.peer(hi, lo) return {lo = lo, hi = hi} end
function F.key(peer) return string.format('%08X%08X', peer.hi, peer.lo) end

-- modules: {G = game.lua, R = region.lua (optional)}; scenario knobs are
-- world fields (see below).
function F.new(modules)
    local G = modules.G
    local world = {bytes = {}, unmapped = {}, calls = {}, frame = 0}
    local bytes = world.bytes

    local function put8(address, value) bytes[address] = value % 256 end
    local function put32(address, value)
        value = value % 4294967296
        for i = 0, 3 do bytes[address + i] = value % 256; value = (value - value % 256) / 256 end
    end
    local function get32(address)
        local value = 0
        for i = 3, 0, -1 do value = value * 256 + (bytes[address + i] or 0) end
        return value
    end
    local function put64(address, value) local lo, hi = u64_parts(value); put32(address, lo); put32(address + 4, hi) end
    local function get64(address) return get32(address) + get32(address + 4) * 4294967296 end
    local function put_string(address, text)
        for i = 1, #text do bytes[address + i - 1] = text:byte(i) end
        bytes[address + #text] = 0
    end
    local function get_string(address, limit)
        local out = {}
        for i = 0, (limit or 256) - 1 do
            local b = bytes[address + i] or 0
            if b == 0 then break end
            out[#out + 1] = string.char(b)
        end
        return table.concat(out)
    end
    world.put32, world.get32, world.put64, world.get64 = put32, get32, put64, get64
    world.put_string, world.get_string, world.put8 = put_string, get_string, put8

    local function record(name, ...)
        world.calls[#world.calls + 1] = {name = name, ...}
    end
    function world.count(name)
        local n = 0
        for _, call in ipairs(world.calls) do if call.name == name then n = n + 1 end end
        return n
    end
    function world.last(name)
        for i = #world.calls, 1, -1 do if world.calls[i].name == name then return world.calls[i] end end
    end

    -- The fake api.
    local api = {queries = 0, scratch = F.SCRATCH, SCRATCH_SIZE = 1024}
    local function mapped(address) return not world.unmapped[address] end
    function api.load8(address) return bytes[address] or 0 end
    function api.load32(address) return get32(address) end
    local float_bits = ffi.new('union { uint32_t u; float f; }')
    function api.loadf(address) float_bits.u = get32(address); return float_bits.f end
    function world.putf(address, value) float_bits.f = value; put32(address, float_bits.u) end
    function api.load64(address) return get64(address) end
    function api.read32(address) if not mapped(address) then return nil end return get32(address) end
    function api.read64(address) if not mapped(address) then return nil end return get64(address) end
    function api.read_f32(address)
        if not mapped(address) then return nil end
        float_bits.u = get32(address)
        return float_bits.f
    end
    local next_buffer = F.BUFFERS
    function api.buffer(size)
        local address = next_buffer
        next_buffer = next_buffer + size + 0x1000
        return address
    end
    function api.read_block(address, buffer, size)
        if not mapped(address) then return false end
        for i = 0, size - 1 do bytes[buffer + i] = bytes[address + i] end
        return true
    end
    function api.writable_data() api.queries = api.queries + 1; return not world.readonly end
    function api.write_f32(address, value)
        if not api.writable_data(address, 4) then return false end
        world.putf(address, value); return true
    end
    function api.write32(address, value)
        if not api.writable_data(address, 4) then return false end
        put32(address, value); return true
    end
    function api.write_words(address, size, words)
        if not api.writable_data(address, size) then return false end
        for i = 1, #words, 2 do put32(address + words[i], words[i + 1]) end
        return true
    end
    world.modules = {}
    function api.module(name)
        if name == 'game.dll' then return not world.no_game and F.GAME or nil end
        if name == G.PLAYFAB_DLL then return not world.no_playfab and F.PLAYFAB or nil end
        if world.modules[name] ~= nil then return world.modules[name] or nil end
        return F.EXE
    end
    function api.module_sha256(module)
        if module == F.GAME then return world.game_sha or 'GAME' end
        return world.exe_sha or 'EXE'
    end
    world.code = {}
    function api.bytes(address, size)
        local code = world.code[address]
        assert(code, string.format('unexpected code read at 0x%x', address))
        if world.changed == address then return ('\0'):rep(size) end
        return code:sub(1, size)
    end
    function api.export(module, name)
        if world.missing_export == name then return nil end
        if world.export_at and world.export_at[name] then return world.export_at[name] end
        return module + #name
    end
    world.natives = {}
    function api.native(type_name, address)
        local fn = world.natives[address]
        assert(fn, string.format('no fake native at 0x%x (%s)', address, type_name))
        return fn
    end
    function api.cstring(address, limit) if address == 0 then return nil end return get_string(address, limit) end
    function api.zero(address, size) for i = 0, size - 1 do bytes[address + i] = nil end end
    function api.put_string(address, text, capacity)
        assert(#text < capacity, 'string too long for its buffer')
        put_string(address, text)
    end
    function api.put64(address, value) put64(address, value) end
    function api.put32(address, value) put32(address, value) end
    -- Peer ids stay exact: u64 returns a key string the fake natives understand.
    function api.u64(lo, hi) return string.format('%08X%08X', hi, lo) end
    function api.u64_decimal(lo, hi) return (tostring(ffi.cast('uint64_t', hi) * 4294967296ULL + lo):gsub('ULL$', '')) end
    function api.u64_hex(lo, hi)
        if hi == 0 then return string.format('%X', lo) end
        return string.format('%X%08X', hi, lo)
    end
    world.api = api

    -- Code the mod verifies.
    for _, code in ipairs(G.CODE) do world.code[F.GAME + code.rva] = code.bytes end
    for _, code in ipairs(modules.R and modules.R.CODE or {}) do world.code[F.GAME + code.rva] = code.bytes end
    for _, code in ipairs(G.EXE_CODE) do world.code[F.EXE + code.rva] = code.bytes end
    for _, native in pairs(G.NATIVES) do world.code[F.GAME + native.rva] = native.bytes end
    put64(F.GAME + G.ENGINE_API_PTR, F.TABLES)
    put64(F.TABLES + G.LOBBY_API, F.LOBBY_API)
    local slot_address = {clear_filters = F.EXE + 0x8c7620, continent = F.EXE + 0x8c5f20}
    for name, slot in pairs(G.ENGINE_SLOTS) do
        put64(F.LOBBY_API + slot.slot, slot_address[name])
        world.code[slot_address[name]] = slot.bytes
    end
    put64(F.TABLES + G.PACKAGE_API, F.PACKAGE_API)
    local package_address = {unload_paused = F.EXE + 0x321730, pause_unloads = F.EXE + 0x321750}
    for name, slot in pairs(G.PACKAGE_SLOTS) do
        put64(F.PACKAGE_API + slot.slot, package_address[name])
        world.code[package_address[name]] = slot.bytes
    end

    -- Game state: context, session, lobby, browser, matchmaking.
    put64(F.GAME + G.CONTEXT_PTR, F.CTX)
    put64(F.GAME + G.GAME_STATE_PTR, F.STATE)
    put64(F.GAME + G.ROSTER_PTR, F.ROSTER)
    put64(F.GAME + G.MATCHMAKING_PTR, F.MATCH)
    put64(F.CTX + G.LOBBY, F.ENGINE_LOBBY)
    put64(F.ENGINE_LOBBY + G.ENGINE_LOBBY_PLAYFAB, F.PLAYFAB_LOBBY)
    put32(F.PLAYFAB_LOBBY + G.PL_STATE, 3)
    -- The live handle, an opaque token beyond a double's exact range.
    put32(F.PLAYFAB_LOBBY + G.PL_HANDLE, 0x5e6f7081)
    put32(F.PLAYFAB_LOBBY + G.PL_HANDLE + 4, 0x1a2b3c4d)
    put64(F.CTX + G.BROWSER, 0x2c000000000)

    world.local_peer = F.peer(0x0a1b2c3d, 0x4e5f6071)
    world.session = {world.local_peer}
    world.host = world.local_peer
    world.mode = G.MODE_SHIP
    world.hosting, world.transition, world.join_state, world.party_join = 1, 0, 0, 0
    world.names = {}
    world.friends = {}
    world.requests = {0, 0}

    -- Writes the scenario into memory; call before each frame.
    function world.sync()
        put32(F.STATE + G.MODE, world.mode)
        put32(F.CTX + G.LOCAL, world.local_peer.lo); put32(F.CTX + G.LOCAL + 4, world.local_peer.hi)
        put32(F.CTX + G.HOST, world.host.lo); put32(F.CTX + G.HOST + 4, world.host.hi)
        put32(F.CTX + G.PEER_COUNT, #world.session)
        for i, peer in ipairs(world.session) do
            local entry = F.CTX + G.PEERS + (i - 1) * G.PEER_STRIDE
            put32(entry, peer.lo); put32(entry + 4, peer.hi); put32(entry + G.PEER_INDEX, peer.index or (i - 1))
        end
        put32(F.CTX + G.HOST_SYNC + G.HS_STATE, world.hosting)
        put32(F.CTX + G.HOST_SYNC + G.HS_TRANSITION, world.transition)
        put32(F.CTX + G.JOIN, world.join_state)
        put8(F.CTX + G.CLIENT_SYNC + G.CS_PARTY_JOIN, world.party_join)
        for slot = 0, 3 do
            local record = F.ROSTER + slot * 0xc0
            local peer = world.session[slot + 1]
            if peer then
                put32(record, peer.lo); put32(record + 4, peer.hi)
                put_string(record + 8, world.names[F.key(peer)] or ('Diver' .. (slot + 1)))
            else
                put32(record, 0); put32(record + 4, 0)
            end
        end
        for i, offset in ipairs(G.REQUESTS) do put32(F.MATCH + offset + 4, world.requests[i]) end
        local members = #world.session
        for _ in pairs(world.lingering or {}) do members = members + 1 end
        put32(F.PLAYFAB_LOBBY + G.PL_MEMBERS, members)
    end

    local function remove_from_session(key)
        for i, peer in ipairs(world.session) do
            if F.key(peer) == key then table.remove(world.session, i); return true end
        end
        return false
    end
    world.remove_from_session = remove_from_session

    -- Browser: world.lobby_after = searches before the successor's lobby is listed.
    world.browser = {busy = 0, count = 0, searches = 0, filters = {}}
    world.search_frames = 2
    world.lobby_after = 1
    world.join_outcome = 'success'   -- or 'refused' or 'stall'
    world.join_frames = 3

    local N = world.natives
    local function at(native) return F.GAME + G.NATIVES[native].rva end
    -- The game's kick: the kick message, then remove_peer(Kicked). keep_removed
    -- leaves the peer in the session (a kick the network has not applied yet).
    N[at('kick_peer')] = function(host_sync, peer)
        record('kick_peer', host_sync, peer)
        if not world.keep_removed then remove_from_session(peer) end
        -- kick_message_lost: the client never learns it was kicked and stays
        -- in the PlayFab lobby with its Helldiver (the v0.4-diag1 test).
        if world.kick_message_lost then world.lingering[peer] = true end
        if world.on_removed then world.on_removed(peer, true) end
    end
    -- The kick message alone: a client that obeys leaves by itself
    -- world.leave_frames later (unless message_ignored).
    world.lingering, world.pending_leaves, world.leave_frames = {}, {}, 2
    N[at('send_kick')] = function(peer)
        record('send_kick', peer)
        if not world.message_ignored then
            world.pending_leaves[#world.pending_leaves + 1] = {key = peer, frame = world.frame + world.leave_frames}
        end
    end
    -- The engine's unload pause flag: world.unload_paused, or the package
    -- manager's byte once install_engine has laid the engine out.
    world.unload_paused = 0
    N[package_address.unload_paused] = function()
        record('unload_paused')
        return world.pause_flag and (bytes[world.pause_flag] or 0) or world.unload_paused
    end
    N[package_address.pause_unloads] = function(value)
        record('pause_unloads', value)
        local flag = value ~= 0 and 1 or 0
        if world.pause_flag then bytes[world.pause_flag] = flag else world.unload_paused = flag end
    end
    N[at('is_friend')] = function(_, peer) return world.friends[peer] and 1 or 0 end
    N[at('filter_string')] = function(field, key, value, op)
        record('filter_string', field, key, get_string(value, 32), op)
        world.browser.filters[#world.browser.filters + 1] = {key = key, value = get_string(value, 32), op = op}
    end
    N[at('browser_start')] = function(field)
        record('browser_start', field)
        world.browser.busy = world.search_frames
        -- A search for the host's own id (the diagnostic control search) finds
        -- its own lobby unless own_lobby_unlisted; others count as successor searches.
        local filter = world.browser.filters[#world.browser.filters]
        world.browser.own = filter and filter.value == api.u64_decimal(world.local_peer.lo, world.local_peer.hi)
        if world.browser.own then
            world.browser.count = world.own_lobby_unlisted and 0 or 1
            return 0
        end
        world.browser.searches = world.browser.searches + 1
        world.browser.count = world.browser.searches >= world.lobby_after and 1 or 0
        return 0
    end
    N[at('browser_busy')] = function(field)
        record('browser_busy', field)
        return world.browser.busy > 0 and 1 or 0
    end
    N[at('browser_count')] = function(field) record('browser_count', field); return world.browser.count end
    N[at('browser_result')] = function(field, out, index)
        record('browser_result', field, out, index)
        put_string(out, world.browser.own and 'own-lobby' or ('lobby-' .. index))
        put_string(out + 72, world.empty_connection and '' or 'connection-string-of-successor')
        return out
    end
    -- PlayFab reads of the host's own lobby (the diagnostic lobby report).
    world.access_policy = 0
    world.search_properties = {{'string_key1', '1.8.46015'},
        {'string_key2', api.u64_decimal(world.local_peer.lo, world.local_peer.hi)},
        {'string_key6', 'NA'}, {'number_key6', '0'}}
    local PF_STRINGS = 0x2f000000000
    N[F.PLAYFAB + #'PFLobbyGetAccessPolicy'] = function(handle, out)
        record('get_access_policy', handle)
        put32(out, world.access_policy)
        return 0
    end
    N[F.PLAYFAB + #'PFLobbyGetSearchPropertyKeys'] = function(handle, count_out, keys_out)
        record('get_search_keys', handle)
        local array = PF_STRINGS
        for i, property in ipairs(world.search_properties) do
            local text = PF_STRINGS + 0x100 * i
            put_string(text, property[1])
            put64(array + (i - 1) * 8, text)
        end
        put32(count_out, #world.search_properties)
        put64(keys_out, array)
        return 0
    end
    N[F.PLAYFAB + #'PFLobbyGetSearchProperty'] = function(handle, key, value_out)
        local name = get_string(key, 64)
        for i, property in ipairs(world.search_properties) do
            if property[1] == name then
                local text = PF_STRINGS + 0x100 * i + 0x80
                put_string(text, property[2])
                put64(value_out, text)
                return 0
            end
        end
        return -2147023728
    end
    N[at('start_join')] = function(join, info, kind, unused, reason)
        record('start_join', join, get_string(info + 72, 128), kind, unused, reason)
        if world.join_refuses_start then return 0 end
        world.join_state, world.hosting, world.join_started = 1, 2, world.frame
        return 1
    end
    N[slot_address.clear_filters] = function(handle)
        record('clear_filters', handle)
        world.browser.filters = {}
    end
    N[slot_address.continent] = function() return world.continent and F.CONTINENT_TEXT or 0 end

    -- Advances the scenario by one frame (leaves, browser, join).
    function world.tick()
        world.frame = world.frame + 1
        for i = #world.pending_leaves, 1, -1 do
            local leave = world.pending_leaves[i]
            if world.frame >= leave.frame then
                table.remove(world.pending_leaves, i)
                if remove_from_session(leave.key) and world.on_removed then world.on_removed(leave.key, false) end
            end
        end
        if world.browser.busy > 0 then world.browser.busy = world.browser.busy - 1 end
        if world.join_state == 1 and world.join_started and world.frame - world.join_started >= world.join_frames then
            if world.join_outcome == 'success' then
                world.host = world.successor or world.host
                world.join_state, world.hosting = 0, 0
                if world.arrivals then world.session = world.arrivals end
            elseif world.join_outcome == 'refused' then
                world.join_state, world.hosting = 0, 1
            end
            world.join_started = nil
        end
        world.sync()
    end

    world.sync()
    return world
end

-- The Galactic Map scanner (src/scanner.lua): its code, the online config
-- object with the recharge field (world.scanner_value, the game's 20 unless
-- set) and the countdown in the matchmaking object.
F.SCANNER_CONFIG = 0x2c600000000
function F.install_scanner(world, S)
    for _, code in ipairs(S.CODE) do world.code[F.GAME + code.rva] = code.bytes end
    world.put64(F.GAME + S.CONFIG_PTR_RVA, F.SCANNER_CONFIG)
    world.put32(F.SCANNER_CONFIG + S.RECHARGE, world.scanner_value or 20)
    world.putf(F.MATCH + S.COUNTDOWN, 0)
end

-- The escape menu's GAME tab laid out like the game's (see src/menu.lua), with
-- fake natives for the menu calls. world.open_menu(), world.close_menu(),
-- world.focus(i), world.select(), world.answer(confirmed), world.hide_dialog(),
-- world.open_popup(card, peer), world.game_rebuild(types). The escape menu's
-- presenter exists while it is open; a pending close set on it closes the menu
-- in the next world.menu_update (recorded as 'escape_closed'), as Esc does.
F.MENU, F.SCREEN, F.PRESENTERS, F.MAIN = 0x2c100000000, 0x2c200000000, 0x2c400000000, 0x2c500000000
function F.install_menu(world, M, options)
    options = options or {}
    local api = world.api
    for _, code in ipairs(M.CODE) do world.code[F.GAME + code.rva] = code.bytes end
    for _, native in pairs(M.NATIVES) do world.code[F.GAME + native.rva] = native.bytes end
    local content = F.SCREEN + M.CONTENT
    local dialog = content + M.DIALOG
    world.content, world.dialog = content, dialog
    world.put64(F.GAME + M.MENU_SYSTEM_PTR, F.MENU)
    world.put64(F.MENU + M.SCREEN, 0)
    world.put64(F.GAME + M.PRESENTERS_PTR, F.PRESENTERS)
    world.put64(F.PRESENTERS + M.MAIN_PRESENTER, 0)
    world.texts, world.labels, world.parents = {}, {}, {}
    local function put8(address, value) world.bytes[address] = value % 256 end
    local function button(i) return content + M.BUTTONS + i * M.BUTTON_SIZE end
    world.button = button
    -- Text widgets: kind in flag bits 18-21 (7 plain, 8 wrapped).
    local function text_widget(address, kind) world.put32(address, kind * 262144) end
    for i = 0, M.MAX_BUTTONS - 1 do
        text_widget(button(i) + M.BUTTON_TEXT, options.button_kind or 7)
        world.putf(button(i) + M.WIDGET_WIDTH, options.button_width or 420)
        world.putf(button(i) + M.BUTTON_TEXT + M.WIDGET_X, 16)
    end
    world.marquees = {}
    text_widget(dialog + M.DIALOG_TITLE, 7)
    text_widget(dialog + M.DIALOG_BODY, 8)
    -- The game's own list: types, count, labels, enabled flags.
    function world.game_rebuild(types)
        types = types or world.native_types or {1, 3}
        world.native_types = types
        for i = 0, M.MAX_BUTTONS - 1 do
            put8(content + M.TYPES + i, types[i + 1] or 0)
            world.put32(button(i), i < #types and 0x45011 or 0x4500b)
            world.parents[button(i)] = i < #types and (content + M.BUTTON_LIST) or nil
            world.labels[button(i) + M.BUTTON_TEXT] = types[i + 1] and M.NATIVE_LABELS[types[i + 1]] or nil
            world.texts[button(i) + M.BUTTON_TEXT] = nil
        end
        put8(content + M.COUNT, #types)
    end
    local function card_at(i) return content + M.CARDS + i * M.CARD_SIZE end
    world.card = card_at
    -- The tab's refresh: one card per squad member, each with its peer and player menu.
    function world.fill_cards()
        for i = 0, 3 do
            local peer = world.session[i + 1]
            world.put32(card_at(i) + M.CARD_PEER, peer and peer.lo or 0)
            world.put32(card_at(i) + M.CARD_PEER + 4, peer and peer.hi or 0)
            world.put64(card_at(i) + M.CARD_POPUP, peer and 0x2c300000000 + i or 0)
        end
    end
    function world.open_menu(shown)
        world.put64(F.MENU + M.SCREEN, F.SCREEN)
        world.put64(F.PRESENTERS + M.MAIN_PRESENTER, F.MAIN)
        world.put32(F.MAIN + M.PENDING_CLOSE, 0)
        world.put32(F.SCREEN + M.SHOWN, shown or 0)
        put8(content + M.HIDDEN, 0)
        put8(content + M.FOCUS, 255)
        put8(content + M.DIALOG_INACTIVE, 1)
        put8(content + M.DIALOG_OPENING, 0)
        put8(content + M.DIALOG_ANSWERED, 0)
        put8(content + M.DIALOG_CONFIRMED, 0)
        world.putf(content + M.DIALOG_FADE, 0)
        world.put32(content + M.PANEL_STATE, 2)
        world.put32(dialog + M.DIALOG_STATE, 0)
        for i = 0, 3 do world.put32(card_at(i) + M.CARD_STATE, 0) end
        world.fill_cards()
        world.game_rebuild(world.native_types)
    end
    -- The tab update's player-menu branch (the game update): with the tab
    -- taking input, the focused card's open popup runs, and its KICK fires
    -- once the hold timer passes 3 s: the game's own kick, then the card reset.
    function world.menu_update()
        local main = world.get64(F.PRESENTERS + M.MAIN_PRESENTER)
        if main ~= 0 and (world.bytes[main + M.PENDING_CLOSE] or 0) ~= 0 then
            world.calls[#world.calls + 1] = {name = 'escape_closed'}
            world.close_menu()
            return
        end
        if world.get64(F.MENU + M.SCREEN) == 0 or world.get32(F.SCREEN + M.SHOWN) ~= 0 then return end
        if (world.bytes[content + M.HIDDEN] or 0) ~= 0 or (world.bytes[content + M.DIALOG_INACTIVE] or 0) == 0
            or (world.bytes[content + M.DIALOG_OPENING] or 0) ~= 0 or api.loadf(content + M.DIALOG_FADE) ~= 0
            or world.get32(content + M.PANEL_STATE) ~= 2 then
            return
        end
        local focus = world.bytes[content + M.FOCUS] or 255
        if focus >= 4 then return end
        local card = card_at(focus)
        if world.get32(card + M.CARD_STATE) ~= M.POPUP_OPEN or world.get64(card + M.CARD_POPUP) == 0 then return end
        if api.loadf(card + M.CARD_KICK_HOLD) >= 3 then
            local key = string.format('%08X%08X', world.get32(card + M.CARD_PEER + 4), world.get32(card + M.CARD_PEER))
            world.calls[#world.calls + 1] = {name = 'game_popup_kick', key}
            if world.game_kick_key then world.game_kick_key(key) else world.remove_from_session(key) end
            world.put64(card + M.CARD_PEER, 0)
            world.put32(card + M.CARD_STATE, 1)
            world.putf(card + M.CARD_KICK_HOLD, 0)
        end
    end
    function world.close_menu()
        world.put64(F.MENU + M.SCREEN, 0)
        world.put64(F.PRESENTERS + M.MAIN_PRESENTER, 0)
    end
    function world.focus(index) put8(content + M.FOCUS, index) end
    -- The game's select handler on the focused button: the common tail shows the dialog.
    function world.select()
        local focus = world.bytes[content + M.FOCUS] or 255
        local kind = world.bytes[content + M.TYPES + focus - 4]
        world.last_select = kind
        put8(content + M.DIALOG_INACTIVE, 0)
        put8(content + M.DIALOG_ANSWERED, 0)
        world.put32(dialog + M.DIALOG_STATE, 1)
    end
    -- Answering hides the dialog in the same frame (0x13FB1A0): inactive at
    -- once, state 3 while it fades out; hide_dialog() finishes the fade.
    function world.answer(confirmed)
        put8(content + M.DIALOG_ANSWERED, 1)
        put8(content + M.DIALOG_CONFIRMED, confirmed and 1 or 0)
        put8(content + M.DIALOG_INACTIVE, 1)
        world.put32(dialog + M.DIALOG_STATE, 3)
    end
    function world.hide_dialog()
        put8(content + M.DIALOG_INACTIVE, 1)
        world.put32(dialog + M.DIALOG_STATE, 0)
    end
    -- Opens card's player menu for peer, or (peer nil) closes it; the card
    -- keeps its player either way, as the game's cards do.
    function world.open_popup(card, peer)
        local address = content + M.CARDS + card * M.CARD_SIZE
        if peer then
            world.put32(address + M.CARD_PEER, peer.lo)
            world.put32(address + M.CARD_PEER + 4, peer.hi)
        end
        world.put32(address + M.CARD_STATE, peer and M.POPUP_OPEN or 0)
    end
    -- What a button shows: its string argument when the template is set, else its label id.
    function world.shown(widget)
        if world.labels[widget] == M.TEXT_TEMPLATE then return world.texts[widget] end
        return world.labels[widget]
    end
    function world.our_buttons()
        local out = {}
        for i = 0, (world.bytes[content + M.COUNT] or 0) - 1 do
            local kind = world.bytes[content + M.TYPES + i]
            if kind >= M.FIRST_TYPE then out[#out + 1] = M.ACTIONS[kind - M.FIRST_TYPE + 1] .. '=' .. tostring(world.shown(button(i) + M.BUTTON_TEXT)) end
        end
        return table.concat(out, ' ')
    end

    local N, ffi = world.natives, require('ffi')
    local function at(name) return F.GAME + M.NATIVES[name].rva end
    local function record(name, ...) world.calls[#world.calls + 1] = {name = name, ...} end
    N[at('add_child')] = function(parent, child) record('add_child', parent, child); world.parents[child] = parent end
    local function set_label(widget, label) world.labels[widget] = label end
    N[at('set_label')] = function(widget, label) record('set_label', widget, label); set_label(widget, label) end
    N[at('set_label_wrapped')] = function(widget, label) record('set_label_wrapped', widget, label); set_label(widget, label) end
    N[at('set_string_arg')] = function(widget, key, text)
        local value = ffi.string(ffi.cast('const char *', text))
        record('set_string_arg', widget, key, value)
        world.texts[widget] = value
    end
    N[at('clear_args')] = function(label) record('clear_args', label); world.texts[label - M.LABEL] = nil; return 1 end
    N[at('measure_text')] = function(widget) record('measure_text', widget) end
    N[at('set_enabled')] = function(widget, on)
        record('set_enabled', widget, on)
        local flags = world.get32(widget)
        world.put32(widget, on ~= 0 and (flags - flags % 32 + flags % 16 + 16) or (flags - (math.floor(flags / 16) % 2) * 16))
    end
    N[at('dialog_setup')] = function(d, title, text, confirm, cancel, hold, flag)
        record('dialog_setup', d, title, text, confirm, cancel, hold, flag)
        set_label(d + M.DIALOG_TITLE, title)
        set_label(d + M.DIALOG_BODY, text)
        world.dialog_buttons = {confirm = confirm, cancel = cancel, hold = hold}
        return 0
    end
    N[at('rebuild')] = function(c, unused) record('rebuild', c, unused); world.game_rebuild(world.native_types) end
    N[at('set_marquee')] = function(widget, width) record('set_marquee', widget, width); world.marquees[widget] = width end
    N[at('focus')] = function(c, index)
        record('focus', c, index)
        local old = world.bytes[content + M.FOCUS] or 255
        if old == index then return end
        if old < 4 then world.put32(card_at(old) + M.CARD_STATE, 0) end
        if index < 4 then world.put32(card_at(index) + M.CARD_STATE, 1) end
        put8(content + M.FOCUS, index)
    end
    N[at('card_state')] = function(card, state)
        record('card_state', card, state)
        if world.get32(card + M.CARD_STATE) ~= state then
            world.put32(card + M.CARD_STATE, state)
            if state ~= M.POPUP_OPEN then world.putf(card + M.CARD_KICK_HOLD, 0) end
        end
    end
    world.native_types = options.native_types or {1, 3}
    world.sync()
end

-- Puts an override config object laid out like the game's into world
-- (inline 512-slot tables, empty key 0, probe multiplier 2) with the server's
-- 16 pairs in OnlineOverrideData. options: code (continent, default 'NA'),
-- continent = false (not known yet), extra / synced = {{own, other, value}}
-- more pairs in OnlineOverrideData / the peer-synced table.
function F.install_config(world, R, options)
    options = options or {}
    local id = {}
    for _, continent in ipairs(R.CONTINENTS) do id[continent[1]] = continent[2] end
    local function pair(own, other) return R.combine({R.KEY_WORDS[1], R.KEY_WORDS[2], id[own], id[other]}) end
    local main, synced = F.CONFIG + R.TABLE, F.CONFIG + R.SYNCED_TABLE
    world.main, world.synced, world.pair = main, synced, pair
    world.put64(F.GAME + R.CONFIG_PTR, F.CONFIG)
    for _, header in ipairs({main, synced}) do
        world.put64(header, header + R.ENTRIES)
        world.put32(header + 8, R.CAPACITY); world.put32(header + 12, 0); world.put32(header + 16, 2)
    end
    for index, continent in ipairs(R.CONTINENTS) do
        world.put32(F.GAME + R.CONTINENT_IDS_RVA + (index - 1) * 4, continent[2])
    end
    world.continent = options.continent ~= false
    world.put_string(F.CONTINENT_TEXT, options.code or 'NA')

    function world.clear(header)
        for address = header + R.ENTRIES, header + R.SPAN - 1 do world.bytes[address] = nil end
        world.put32(header + 20, 0); world.put32(header + R.COUNT, 0); world.put32(header + R.CHECKSUM, 0)
    end
    -- The game's insert: first empty slot on the probe path, count + 1.
    function world.insert(header, key, name, parent, kind, value)
        local start = R.mul32(key, 2)
        for i = 0, R.CAPACITY - 1 do
            local entry = header + R.ENTRIES + ((start + i) % R.CAPACITY) * R.ENTRY_SIZE
            if world.get32(entry) == 0 then
                world.put32(entry, key); world.put32(entry + 8, name); world.put32(entry + 12, parent)
                world.put32(entry + 16, key); world.put32(entry + 20, kind); world.put32(entry + 24, value)
                world.put32(entry + 40, R.WEIGHT)
                world.put32(header + R.COUNT, world.get32(header + R.COUNT) + 1)
                return entry
            end
        end
        error('fake table full')
    end
    local function server_pair(header, own, other, value)
        return world.insert(header, pair(own, other), id[other], F.ROW_KEYS[own] or 0, R.TYPE_BOOL, value)
    end
    -- A config download that changed the table: the game copies the new table
    -- (and its checksum) over OnlineOverrideData.
    function world.download(checksum, extra)
        world.clear(main)
        world.put32(main + 20, R.KEY_WORDS[1])
        world.insert(main, 0xcb9e5905, 0x70e28fdb, 0x6a8b050d, 6, 100) -- an unrelated number entry
        for _, case in ipairs(F.LIVE_PAIRS) do server_pair(main, case[1], case[2], 0) end
        for _, e in ipairs(extra or {}) do server_pair(main, e[1], e[2], e[3]) end
        world.put32(main + R.CHECKSUM, checksum)
    end
    world.download(F.SERVER_CHECKSUM, options.extra)
    world.put32(synced + 20, 0xe4aed9f8)
    world.insert(synced, 0x02e78100, 0x5bd1e995, 0xe4aed9f8, R.TYPE_BOOL, 1)
    for _, e in ipairs(options.synced or {}) do server_pair(synced, e[1], e[2], e[3]) end
    world.put32(synced + R.CHECKSUM, 0x11111111)
    -- What the search builder sees: continents excluded for own, in R.CONTINENTS order.
    function world.excluded(own)
        local out = {}
        for _, continent in ipairs(R.CONTINENTS) do
            for _, header in ipairs({synced, main}) do
                local entry = R.lookup(world.api, header, pair(own, continent[1]))
                if entry then
                    if world.get32(entry + 20) == R.TYPE_BOOL and world.get32(entry + 24) % 256 == 0 then
                        out[#out + 1] = continent[1]
                    end
                    break
                end
            end
        end
        return table.concat(out, ' ')
    end
    world.sync()
end

-- The game's text chat for the squad messages (src/chat.lua): the chat in the
-- network context and the game's chat send, which does what the game's does:
-- nothing while the chat is off (world.chat.enabled false), otherwise the
-- message to every other session peer the host has not muted
-- (world.chat.muted[peer key]), recorded as 'chat_rpc' {peer key, text}, then
-- the line in the host's own chat history (64 lines). The call itself is
-- recorded as 'chat_send' {chat, unused, text}.
function F.install_chat(world, C, G)
    local put32, get32 = world.put32, world.get32
    world.code[F.GAME + C.SEND.rva] = C.SEND.bytes
    world.code[F.GAME + C.RPC.rva] = C.RPC.bytes
    for _, code in ipairs(C.CODE) do world.code[F.GAME + code.rva] = code.bytes end
    world.chat = {enabled = true, muted = {}}
    local chat = F.CTX + C.CHAT
    local function sync()
        world.put8(chat, world.chat.enabled and 1 or 0)
    end
    sync()
    world.chat.sync = sync
    local function record(name, ...) world.calls[#world.calls + 1] = {name = name, ...} end
    world.natives[F.GAME + C.SEND.rva] = function(object, unused, text)
        local line = world.get_string(text, 1100)
        record('chat_send', object, unused, line)
        if object ~= chat or world.bytes[chat] == 0 or #line > C.MAX_TEXT then return end
        local own_lo, own_hi = get32(F.CTX + G.LOCAL), get32(F.CTX + G.LOCAL + 4)
        for i = 0, get32(F.CTX + G.PEER_COUNT) - 1 do
            local entry = F.CTX + G.PEERS + i * G.PEER_STRIDE
            local lo, hi = get32(entry), get32(entry + 4)
            local key = string.format('%08X%08X', hi, lo)
            if (lo ~= own_lo or hi ~= own_hi) and not world.chat.muted[key] then record('chat_rpc', key, line) end
        end
        local first, count = get32(chat + C.HISTORY_FIRST), get32(chat + C.HISTORY_COUNT)
        if count == 64 then put32(chat + C.HISTORY_FIRST, (first + 1) % 64) else put32(chat + C.HISTORY_COUNT, count + 1) end
    end
    -- The game's RPC send, recorded as 'rpc_send' {hash, target, count, first argument's type, size, value key}.
    world.natives[F.GAME + C.RPC.rva] = function(hash, target, args, count)
        local value = world.get64(args + 8)
        record('rpc_send', hash, target, count, get32(args), get32(args + 4),
            string.format('%08X%08X', get32(value + 4), get32(value)))
    end
end

-- The engine side of the kick crash (docs/TECHNICAL.md),
-- laid out like the game's for src/diag.lua: the package queue in the package
-- manager, the resource manager's in-use table and PlayerHistory. Then the
-- consequences of a removal as the game has them:
--   world.gear[peer key] = {packages = {{lo =, hi =, resources = {key, ...}}, ...}, units = {key = true}}
--   (the player's loadout packages and the in-use entries of their Helldiver's units);
--   world.history[peer key] = {inactive, kicked, loadout, type}.
-- A removal (the mod's kick, world.game_kick, world.leave) releases the loadout
-- at once: its packages are queued for unload. The Helldiver despawns
-- world.despawn_frames later, which removes its in-use entries. world.engine_frame()
-- runs the rest of a frame after the Lua update: the game update (due despawns,
-- the game_update callback), then one package queue entry, crashing
-- (world.crashed) when an unload meets a resource still in use, as the engine does.
F.APP, F.PM, F.RM, F.IN_USE, F.HISTORY = 0x2e000000000, 0x2e000100000, 0x2e000200000, 0x2e000300000, 0x2e000400000
F.IN_USE_SLOTS = 64
function F.install_engine(world, D)
    local put32, put64, get32, bytes = world.put32, world.put64, world.get32, world.bytes
    for _, code in ipairs(D.EXE_CODE) do world.code[F.EXE + code.rva] = code.bytes end
    for _, code in ipairs(D.GAME_CODE) do world.code[F.GAME + code.rva] = code.bytes end
    put64(F.EXE + D.APP_PTR, F.APP)
    put64(F.APP + D.PACKAGE_MANAGER, F.PM)
    put64(F.PM + D.RESOURCE_MANAGER, F.RM)
    put32(F.RM + D.IN_USE_SLOTS, F.IN_USE_SLOTS)
    put64(F.RM + D.IN_USE_ENTRIES, F.IN_USE)
    put32(F.RM + D.STRICT, 1)
    put32(F.PM + D.QUEUE_HEAD, 0)
    put32(F.PM + D.QUEUE_TAIL, 0)
    world.pause_flag = F.PM + D.UNLOAD_PAUSED
    bytes[world.pause_flag] = world.unload_paused
    put64(F.GAME + D.HISTORY_PTR, F.HISTORY)
    world.in_use = {[0x3000000100] = {count = 12, name = 0x11111111}, [0x3000000200] = {count = 1, name = 0x22222222}}
    world.gear, world.history, world.despawns, world.processed = {}, {}, {}, {}
    world.history_order = {}
    world.despawn_frames = 3

    local function write_in_use()
        local keys = {}
        for key in pairs(world.in_use) do keys[#keys + 1] = key end
        table.sort(keys)
        assert(#keys <= F.IN_USE_SLOTS, 'fake in-use table full')
        for i = 0, F.IN_USE_SLOTS - 1 do
            local entry, key = F.IN_USE + i * D.IN_USE_STRIDE, keys[i + 1]
            put64(entry, key or 0)
            put32(entry + D.IN_USE_COUNT, key and world.in_use[key].count or 0)
            put32(entry + D.IN_USE_NAME, key and world.in_use[key].name or 0)
            put32(entry + D.IN_USE_NEXT, key and 0x7fffffff or 0xfffffffe)
        end
    end
    local function write_history()
        put32(F.HISTORY + D.HISTORY_COUNT, #world.history_order)
        for i, key in ipairs(world.history_order) do
            local entry, h = F.HISTORY + (i - 1) * D.HISTORY_STRIDE, world.history[key]
            put32(entry, h.lo); put32(entry + 4, h.hi)
            bytes[entry + D.H_INACTIVE], bytes[entry + D.H_KICKED], bytes[entry + D.H_LOADOUT] = h.inactive, h.kicked,
                h.loadout
            put32(entry + D.H_LOAD_TYPE, h.type)
        end
    end
    -- A player on the host's ship: loadout loaded (type 1), Helldiver spawned.
    function world.give_gear(peer, gear)
        local key = F.key(peer)
        world.gear[key] = gear
        for resource in pairs(gear.units) do world.in_use[resource] = {count = 1, name = resource % 0x100000000} end
        if not world.history[key] then world.history_order[#world.history_order + 1] = key end
        world.history[key] = {lo = peer.lo, hi = peer.hi, inactive = 0, kicked = 0, loadout = 1, type = 1}
        write_history()
        write_in_use()
    end
    local function queue(lo, hi, load)
        local tail = get32(F.PM + D.QUEUE_TAIL)
        local entry = F.PM + D.QUEUE + tail * D.QUEUE_STRIDE
        put32(entry, lo); put32(entry + 4, hi); bytes[entry + D.QUEUE_LOAD] = load and 1 or 0
        put32(F.PM + D.QUEUE_TAIL, (tail + 1) % D.QUEUE_SIZE)
    end
    world.queue = queue
    function world.on_removed(key, kicked)
        local h = world.history[key]
        if h then
            h.inactive, h.kicked = 1, kicked and 1 or 0
            if h.loadout == 1 then
                h.loadout = 0
                for _, package in ipairs(world.gear[key] and world.gear[key].packages or {}) do
                    queue(package.lo, package.hi, false)
                end
            end
            write_history()
        end
        -- A client still connected (its kick message lost) keeps its Helldiver.
        if not world.lingering[key] then world.despawns[key] = world.frame + world.despawn_frames end
    end
    local function remove(peer, kicked)
        for i, p in ipairs(world.session) do
            if F.key(p) == F.key(peer) then table.remove(world.session, i); break end
        end
        world.on_removed(F.key(peer), kicked)
    end
    function world.game_kick(peer) remove(peer, true) end
    function world.leave(peer) remove(peer, false) end
    -- The player menu's KICK (install_menu): the game's own kick, whose
    -- removal takes the Helldiver with it at once (test 2's recording).
    function world.game_kick_key(key)
        for _, peer in ipairs(world.session) do
            if F.key(peer) == key then
                remove(peer, true)
                for resource in pairs(world.gear[key] and world.gear[key].units or {}) do world.in_use[resource] = nil end
                world.despawns[key] = nil
                return
            end
        end
    end
    local function package_of(lo, hi)
        for _, gear in pairs(world.gear) do
            for _, package in ipairs(gear.packages) do
                if package.lo == lo and package.hi == hi then return package end
            end
        end
    end
    function world.engine_frame(game_update)
        for key, frame in pairs(world.despawns) do
            if world.frame >= frame then
                for resource in pairs(world.gear[key] and world.gear[key].units or {}) do world.in_use[resource] = nil end
                world.despawns[key] = nil
            end
        end
        if world.menu_update then world.menu_update() end
        if game_update then game_update() end
        local head, tail = get32(F.PM + D.QUEUE_HEAD), get32(F.PM + D.QUEUE_TAIL)
        if head ~= tail then
            local entry = F.PM + D.QUEUE + head * D.QUEUE_STRIDE
            local load = (bytes[entry + D.QUEUE_LOAD] or 0) ~= 0
            if load or (bytes[world.pause_flag] or 0) == 0 then
                local lo, hi = get32(entry), get32(entry + 4)
                local package = package_of(lo, hi)
                for _, resource in ipairs(not load and package and package.resources or {}) do
                    if world.in_use[resource] and not world.crashed then
                        world.crashed = {lo = lo, hi = hi, resource = resource, frame = world.frame}
                    end
                end
                world.processed[#world.processed + 1] = {lo = lo, hi = hi, load = load, frame = world.frame}
                put32(F.PM + D.QUEUE_HEAD, (head + 1) % D.QUEUE_SIZE)
            end
        end
        write_in_use()
        world.sync()
    end
    write_in_use()
    write_history()
end

return F
