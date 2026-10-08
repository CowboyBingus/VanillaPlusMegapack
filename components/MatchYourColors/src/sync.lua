-- Match Your Colors: Sync With Mod Users. Each player's color settings travel as a PlayFab lobby member property of
-- the squad's lobby (KB match-your-colors-multiplayer-visibility, match-your-colors-schemes-sync); every mod user then
-- recolors the others' Helldivers locally (src/remote.lua). Non-modded games read member properties only by their own
-- keys, so the extra key changes nothing for them.
--
-- Lobby (Steam build 25480438, as Better Lobby Management reads it): network context [game + 0x347CEF0], engine
-- lobby +0x1D470, its PlayFab lobby +0x10: members +0x100, state +0x118 (3 = joined), lobby handle +0x120 (an exact
-- 64-bit token: read as uint64, never through a double), the local user's entity key {id, type} +0x130. Entity ids
-- are peer ids in hex without zero padding (KB lobby-manager-session-research). PlayFab's exports come from
-- PlayFabMultiplayerWin.dll (GetModuleHandleA, GetProcAddress once per session).
--
-- Value: '<version>|<mode>|<flags>|<scheme>' (flags: complete sets 1, hoods recolored 2, materials matched 4, cape
-- recolored 8).
-- Posts are rare: once per lobby and after an options change has settled for POST_DELAY_FRAMES; never while not
-- joined (a failed post can set the game's lobby session state 4), and only once the lobby has stayed joined under
-- one handle for STEADY_FRAMES. A post names the local user by PlayFab's own key of the local member (from its member
-- list), never by the game's copy at PL_USER: on arrival on the ship that copy was not yet valid, PFLobbyPostUpdate
-- read a bad string pointer through it and the game crashed (user, 2026-10-07; dump at
-- PlayFabMultiplayerWin+0x5fde4). Reads run on the caller's poll (every POLL_FRAMES): 7 memory reads for the lobby,
-- one member list, then per member 2 reads (the local member's 4) and, for the others while this player shares, one
-- member property and 1 read. All game memory is read through bingus_memory's read_into
-- (pointer objects kept per address); PlayFab's strings are copied the same way. The poll's tables are reused.
local ffi = require('ffi')

local Sync = {}

Sync.KEY, Sync.VERSION, Sync.DLL = 'cbmyc', 1, 'PlayFabMultiplayerWin.dll'
Sync.POLL_FRAMES, Sync.POST_DELAY_FRAMES, Sync.RETRY_FRAMES, Sync.STEADY_FRAMES = 120, 300, 1800, 600
Sync.CONTEXT, Sync.LOBBY, Sync.PLAYFAB = 0x347CEF0, 0x1D470, 0x10
Sync.PL_MEMBERS, Sync.PL_STATE, Sync.PL_HANDLE, Sync.PL_USER = 0x100, 0x118, 0x120, 0x130
Sync.JOINED, Sync.MAX_MEMBERS = 3, 16
local HIGH = 4294967296
local U64 = ffi.typeof('uint64_t')

-- The value for options {mode, keep_sets, recolor_hoods, match_materials, recolor_cape, scheme}.
function Sync.encode(o)
    local flags = (o.keep_sets and 1 or 0) + (o.recolor_hoods and 2 or 0) + (o.match_materials and 4 or 0)
        + (o.recolor_cape and 8 or 0)
    return string.format('%d|%d|%d|%d', Sync.VERSION, o.mode, flags, o.scheme or 0)
end

-- The options a value carries, or nil (another version, or anything malformed).
function Sync.decode(text)
    if type(text) ~= 'string' or #text > 40 then return nil end
    local version, mode, flags, scheme = text:match('^(%d+)|(%d+)|(%d+)|(%d+)$')
    version, mode, flags, scheme = tonumber(version), tonumber(mode), tonumber(flags), tonumber(scheme)
    if version ~= Sync.VERSION or not mode or mode < 1 or mode > 3 or flags > 15 or scheme > 64 then return nil end
    return {mode = mode, keep_sets = flags % 2 == 1, recolor_hoods = math.floor(flags / 2) % 2 == 1,
            match_materials = math.floor(flags / 4) % 2 == 1, recolor_cape = math.floor(flags / 8) % 2 == 1,
            scheme = scheme}
end

-- The peer id of an entity id: up to 16 hex digits (the engine prints peer ids with %llX, no zero padding, and
-- parses entity ids with strtoull base 16) -> low and high 32 bits (exact; no double above 2^53), or nil.
function Sync.peer_of(id)
    if type(id) ~= 'string' or #id < 1 or #id > 16 or id:find('[^%x]') then return nil end
    local padded = string.rep('0', 16 - #id) .. id
    return tonumber(padded:sub(9, 16), 16), tonumber(padded:sub(1, 8), 16)
end

local declared = false
local function declare()
    if declared then return end
    declared = true
    -- Names of their own (the first cdef of a name wins in a Lua state every mod shares); pcall: a second copy of
    -- this module in the same state finds them declared.
    pcall(ffi.cdef, [[
void *MycGetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
void *MycGetProcAddress(void *module, const char *name) __asm__("GetProcAddress");
typedef struct MycEntityKey { const char *id; const char *type; } MycEntityKey;
typedef struct MycMemberUpdate { uint32_t count; const char *const *keys; const char *const *values; } MycMemberUpdate;
typedef int32_t (*MycPostUpdate)(uint64_t lobby, const MycEntityKey *user, const void *lobby_update,
                                 const MycMemberUpdate *member_update, void *context);
typedef int32_t (*MycGetMembers)(uint64_t lobby, uint32_t *count, const MycEntityKey **members);
typedef int32_t (*MycGetMemberProperty)(uint64_t lobby, const MycEntityKey *member, const char *key,
                                        const char **value);
]])
end

-- PlayFab's lobby calls as {post(handle, key address (PlayFab's own key of the local member), text or nil),
-- members(handle) -> count, array address or nil,
-- hresult, property(handle, member address) -> value address or nil, hresult}, or nil and why. Every buffer is made
-- here once; a call allocates only its pointer and result boxes. lookup(name, ctype): an export as ctype or nil
-- (default: PlayFabMultiplayerWin.dll's; tests give their own).
function Sync.natives(lookup)
    declare()
    if not lookup then
        local C = ffi.C
        local module = C.MycGetModuleHandleA(Sync.DLL)
        if module == nil then return nil, Sync.DLL .. ' not loaded' end
        lookup = function(name, ctype)
            local proc = C.MycGetProcAddress(module, name)
            if proc == nil then return nil end
            return ffi.cast(ctype, proc)
        end
    end
    local post = lookup('PFLobbyPostUpdate', 'MycPostUpdate')
    local members = lookup('PFLobbyGetMembers', 'MycGetMembers')
    local property = lookup('PFLobbyGetMemberProperty', 'MycGetMemberProperty')
    if not (post and members and property) then return nil, 'PlayFab lobby exports missing' end
    local KEY_PTR = ffi.typeof('const MycEntityKey *')
    local key, value = ffi.new('char[8]', Sync.KEY), ffi.new('char[48]')
    local keys, values = ffi.new('const char *[1]'), ffi.new('const char *[1]')
    keys[0] = key
    local update = ffi.new('MycMemberUpdate')
    update.count, update.keys, update.values = 1, keys, values
    local count, list, out = ffi.new('uint32_t[1]'), ffi.new('const MycEntityKey *[1]'), ffi.new('const char *[1]')
    -- Every buffer the update points into stays referenced for the session: a pointer stored in a struct field keeps
    -- no cdata alive. The keys array, referenced by nothing else, was collected after this function returned and its
    -- memory reused; PFLobbyPostUpdate then read a garbage key pointer through it and the game crashed (user,
    -- 2026-10-07; dump at PlayFabMultiplayerWin+0x5fde4 reading keys[0] = 0x13FE3012E).
    local api = {keep = {key, value, keys, values, update, count, list, out}}
    function api.post(handle, user, text)
        if text then
            ffi.copy(value, text:sub(1, 47))
            values[0] = value
        else
            values[0] = nil -- removes the key
        end
        return post(handle, ffi.cast(KEY_PTR, user), nil, update, nil)
    end
    function api.members(handle)
        local result = members(handle, count, list)
        if result ~= 0 then return nil, nil, result end
        return count[0], tonumber(ffi.cast(U64, list[0])), 0
    end
    function api.property(handle, member)
        out[0] = nil
        local result = property(handle, ffi.cast(KEY_PTR, member), key, out)
        if result ~= 0 then return nil, result end
        if out[0] == nil then return nil, 0 end
        return tonumber(ffi.cast(U64, out[0])), 0
    end
    return api
end

-- Safe reads for the session into one buffer: u32 and u64 (an address as a number) or nil, halves (a 64-bit value's
-- low and high 32 bits) or nil, text (a C string up to 47 bytes) or nil. One pointer object per address is kept
-- (the lobby's addresses are stable; the cache starts over at 256). memory: bingus_memory.
local TEXT_SIZES = {47, 24, 16, 8}
local function reader(memory)
    local U8P = ffi.typeof('const uint8_t *')
    local bytes = ffi.new('uint8_t[64]')
    local pointers, cached = {}, 0
    local self = {}
    local function read(address, size)
        if not address or address < 0x10000 or address >= 0x800000000000 then return nil end
        local p = pointers[address]
        if not p then
            if cached >= 256 then pointers, cached = {}, 0 end
            p = ffi.cast(U8P, address)
            pointers[address], cached = p, cached + 1
        end
        return memory.read_into(p, size, bytes) and bytes or nil
    end
    local function u32_at(b, o) return b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216 end
    function self.u32(address)
        local b = read(address, 4)
        return b and u32_at(b, 0) or nil
    end
    function self.halves(address)
        local b = read(address, 8)
        if not b then return nil end
        return u32_at(b, 0), u32_at(b, 4)
    end
    function self.u64(address)
        local low, high = self.halves(address)
        return low and low + high * HIGH or nil
    end
    function self.text(address)
        for _, size in ipairs(TEXT_SIZES) do
            local b = read(address, size)
            if b then
                local n = 0
                while n < size and b[n] ~= 0 do n = n + 1 end
                return ffi.string(b, n)
            end
        end
        return nil
    end
    return self
end

-- The squad's PlayFab lobby into out (reused): {low, high (its handle's halves), handle (uint64, made once per
-- lobby), id (the local entity id, read through the game's copy of the key: only compared, never handed to PlayFab),
-- joined, since (the poll frame it was first seen joined under this handle; the caller sets it)}; out, or nil.
local function lobby(read, game, out)
    local context = read.u64(game + Sync.CONTEXT)
    local engine = context and read.u64(context + Sync.LOBBY)
    local pl = engine and read.u64(engine + Sync.PLAYFAB)
    if not pl then return nil end
    local low, high = read.halves(pl + Sync.PL_HANDLE)
    if not low or (low == 0 and high == 0) then return nil end
    if low ~= out.low or high ~= out.high then
        out.low, out.high, out.handle = low, high, ffi.cast(U64, high) * HIGH + low -- uint64 arithmetic: exact
        out.since = nil
    end
    local id_at = read.u64(pl + Sync.PL_USER)
    out.id = id_at and read.text(id_at) or nil
    out.joined = read.u32(pl + Sync.PL_STATE) == Sync.JOINED
    return out
end

-- A sync session. deps: {memory, game, natives (Sync.natives or a test's), note}. poll(frame, text, include_local)
-- posts text (nil: sharing off) when due and returns the members' values {{peer_low, peer_high, text (or nil), local},
-- ...} (a list the next poll reuses), or nil outside a joined lobby and while sharing is off. include_local: the
-- local member too (the test build's loopback).
function Sync.session(deps)
    local read = reader(deps.memory)
    local api, why_not
    local current, list, records = {}, {}, {}
    local self = {posted_low = nil, posted_high = nil, posted_text = nil, pending = nil, changed_at = 0, next_post = 0,
                  posts = 0, failures = 0}

    local function natives()
        if api == nil and why_not == nil then
            api, why_not = deps.natives()
            if not api then deps.note('Sync: ' .. tostring(why_not) .. '.') end
        end
        return api
    end

    local function posted_here(l) return l.low == self.posted_low and l.high == self.posted_high end

    -- Posts the value when it differs from what this lobby has and it has not changed for POST_DELAY_FRAMES, once
    -- the lobby has stayed joined for STEADY_FRAMES and its member list holds the local member (l.own: PlayFab's own
    -- key of it, from this poll's member list).
    local function maybe_post(frame, l, text)
        if text ~= self.pending then self.pending, self.changed_at = text, frame end
        local due = text ~= self.posted_text or not posted_here(l)
        if not due or frame < self.next_post or frame - self.changed_at < Sync.POST_DELAY_FRAMES then return end
        if text == nil and not posted_here(l) then -- nothing of ours in this lobby to remove
            self.posted_low, self.posted_high, self.posted_text = l.low, l.high, nil
            return
        end
        if not l.own or frame - l.since < Sync.STEADY_FRAMES then return end
        local result = api.post(l.handle, l.own, text)
        self.next_post = frame + Sync.POST_DELAY_FRAMES
        if result == 0 then
            self.posted_low, self.posted_high, self.posted_text = l.low, l.high, text
            self.posts = self.posts + 1
            deps.note(text and ('Sync: shared ' .. text .. '.') or 'Sync: sharing removed.')
        else
            self.failures, self.next_post = self.failures + 1, frame + Sync.RETRY_FRAMES
            deps.note(string.format('Sync: post failed (0x%08X); retrying later.', result % HIGH))
        end
    end

    -- The members' values (the local member's only with include_local) into list (reused); l.own: PlayFab's own key
    -- of the local member when its id and type read as text, else nil.
    local function members(l, include_local)
        for i = #list, 1, -1 do list[i] = nil end
        l.own = nil
        local count, array = api.members(l.handle)
        if not count then return list end
        for i = 0, math.min(count, Sync.MAX_MEMBERS) - 1 do
            local key_at = array + 16 * i
            local id = read.text(read.u64(key_at))
            local low, high = Sync.peer_of(id)
            local own = id ~= nil and id == l.id
            if own and read.text(read.u64(key_at + 8)) then l.own = key_at end
            if low and (include_local or not own) then
                local value_at = api.property(l.handle, key_at)
                local n = #list + 1
                local r = records[n] or {}
                records[n] = r
                r.peer_low, r.peer_high, r['local'] = low, high, own
                r.text = value_at and read.text(value_at) or nil
                list[n] = r
            end
        end
        return list
    end

    function self.poll(frame, text, include_local)
        local l = lobby(read, deps.game, current)
        -- Without the local entity id the local member cannot be told apart: nothing is read then.
        if not l or not l.joined or not l.id or not natives() then
            if l then l.since = nil end
            return nil
        end
        l.since = l.since or frame
        local found = members(l, include_local)
        maybe_post(frame, l, text)
        if text == nil then return nil end -- only players who share read the others' values
        return found
    end
    return self
end

-- Runs on the sync poll and at startup, never per frame: interpreted (no traces in the LuaJIT code cache every mod
-- shares).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({Sync.encode, Sync.decode, Sync.peer_of, declare, Sync.natives, reader, lobby,
                         Sync.session}) do
        jit.off(fn, true)
    end
end

return Sync
