-- Match Your Colors: the squad cards (v1.5, user 2026-10-15: "The squad preview window is broken. None of the squad
-- matching appears there."). The loadout screen shows each player's Helldiver in a UiPreviewSystem player slot
-- (src/preview.lua), placed by the player's session slot and dressed in the player's desired kits (game.dll card
-- widget 0x18a17d0, Steam build 25480438; KB match-your-colors-squad-cards). v1.5 watched only the Armory's slot
-- (u32 [pm + 948]) and took it for the player's own: after a join a squadmate's card sat there and took this player's
-- options, and no other card was recolored.
--
-- Owners (Lineup.owners), read again only when a slot shows, changes or goes: the network context [game + 0x347CEF0],
-- its session peers (count +0x16390, 32-byte entries from +0x16398: u64 peer +0, u32 UI slot +20) and the local peer
-- (+0xB398). A slot listed for the local peer is the player's own preview; one listed for another peer is that peer's
-- card when it shows a squadmate's desired kits (src/avatar.lua Avatar.others_desired, as the card code reads them;
-- the player manager's peer ids are not used: they can be 0); any other shown slot is the player's own when it is the
-- Armory's, else nobody's (left as it is).
--
-- The player's own preview stays the addon's (its slot returned by observe). Every other card takes its player's
-- settings from the last lobby poll (src/remote.lua wanted: their own shared settings, or this player's with Recolor
-- Squadmates); a card without settings keeps its own colors. Each card has a controller of its own; its job runs in
-- the addon's single job slot after the local Helldiver's and the local preview's; new units with the kits and settings
-- of its applied plan are bound at once; a card that goes is restored. One card's bindings are checked per
-- CHECK_FRAMES.
local Lineup = {}

Lineup.FAILURE_LIMIT = 3
Lineup.CONTEXT = 0x347CEF0
local SESSION, SESSION_BYTES, ENTRY_BYTES, ENTRY_SLOT, MAX_ENTRIES, LOCAL_PEER = 0x16390, 136, 32, 20, 4, 0xB398
local SLOTS = 4
local HIGH = 4294967296

local function u32(p, o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
-- A peer's key, as src/remote.lua keys lobby members (16 hex digits).
local function key_of(low, high) return string.format('%08x%08x', high, low) end

-- The session's peers by UI slot into lows and highs (reused; false for a slot nobody holds) and the local peer's
-- halves (nil without a network context). 3 reads.
local function session_peers(read, game, lows, highs)
    for s = 0, SLOTS - 1 do lows[s], highs[s] = false, false end
    local b = read(game + Lineup.CONTEXT, 8)
    local context = b and u32(b, 0) + u32(b, 4) * HIGH
    if not context or context < 0x10000 or context >= 0x800000000000 then return nil end
    b = read(context + LOCAL_PEER, 8)
    if not b then return nil end
    local low, high = u32(b, 0), u32(b, 4)
    b = read(context + SESSION, SESSION_BYTES)
    if not b then return low, high end
    for i = 0, math.min(u32(b, 0), MAX_ENTRIES) - 1 do
        local o = 8 + ENTRY_BYTES * i
        local slot, peer_low, peer_high = u32(b, o + ENTRY_SLOT), u32(b, o), u32(b, o + 4)
        if slot < SLOTS and (peer_low ~= 0 or peer_high ~= 0) then lows[slot], highs[slot] = peer_low, peer_high end
    end
    return low, high
end

-- The session's peers for the log ('00c0ffee5eed0001 slot 0 (this machine's), ...'; src/remote.lua's note on a member
-- that names none of the players here).
function Lineup.session_text(read, game)
    local lows, highs = {}, {}
    local low, high = session_peers(read, game, lows, highs)
    if not low then return 'no session' end
    local parts = {}
    for s = 0, SLOTS - 1 do
        if lows[s] then
            parts[#parts + 1] = string.format('%s slot %d%s', key_of(lows[s], highs[s]), s,
                (lows[s] == low and highs[s] == high) and " (this machine's)" or '')
        end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'no session peers'
end

-- Whether a squadmate wants the kits slot s of watch shows (helmet, armor and cape): desired, the desired kits of the
-- players not owned here (count n; Avatar.others_desired).
local function worn(desired, n, watch, s)
    local helmet, armor, _, cape = watch.slot_kits(s)
    for i = 1, n do
        local kits = desired[i]
        if kits[1] == helmet and kits[2] == armor and kits[3] == cape then return true end
    end
    return false
end

-- The owner of each shown player slot into out (reused): 'local' (the player's own preview), a squadmate's peer key
-- (their card: the session gives the slot to that peer and it shows a squadmate's desired kits) or false (nobody
-- found; also every slot not shown). watch: src/preview.lua's; own: the Armory's slot (u32 [pm + 948]).
local lows, highs, desired = {}, {}, {} -- the session's peers by slot (session_peers); the squadmates' desired kits
function Lineup.owners(read, game, Avatar, watch, own, out)
    local low, high = session_peers(read, game, lows, highs)
    local n -- the squadmates' desired kits, read when a slot of another peer is shown
    for s = 0, SLOTS - 1 do
        local peer_low, peer_high, owner = lows[s], highs[s], false
        local shown = watch.status(s) ~= 'absent'
        local other = shown and peer_low and not (peer_low == low and peer_high == high)
        if other then n = n or Avatar.others_desired(read, game, desired) end
        if shown and peer_low and not other then
            owner = 'local'
        elseif other and worn(desired, n, watch, s) then
            owner = key_of(peer_low, peer_high)
        elseif shown and s == own then
            owner = 'local'
        end
        out[s] = owner
    end
    return out
end

-- The owners in one line for the log ('slot 0 0000000000001234 (your settings), slot 1 you'), or nil when every shown
-- slot is the player's own (the Armory alone).
local function owners_text(owners, wanted, mine)
    local parts, others = {}, false
    for s = 0, SLOTS - 1 do
        local owner = owners[s]
        if owner == 'local' then
            parts[#parts + 1] = 'slot ' .. s .. ' you'
        elseif owner then
            local settings = wanted[owner]
            parts[#parts + 1] = string.format('slot %d %s (%s)', s, owner, not settings and 'keeps its colors'
                or (settings == mine and 'your settings' or 'shared settings'))
            others = true
        end
    end
    return others and table.concat(parts, ', ') or nil
end

-- m: {Avatar, Recolor, Engine, memory, native, pool, game, read (Avatar.reader), note, remote (src/remote.lua),
-- records_same (the addon's)}.
function Lineup.new(m)
    local Avatar, Recolor, remote, note = m.Avatar, m.Recolor, m.remote, m.note
    -- remap: the owners are read again at the next observe; stale: the cards look at their settings again
    -- (a lobby poll); busy: a card has textures to give back or units to bind once they are ready.
    local self = {cards = {}, pending = false, busy = false, remap = true, stale = false, served = SLOTS - 1, jobs = 0,
                  rebinds = 0}
    local owners, retiring = {}, {}
    remote.session_text = Lineup.session_text -- for its note on a member that names no player here
    for s = 0, SLOTS - 1 do owners[s] = false end
    local watch, logged, cursor = nil, nil, 0

    local function cape_counts(r) return r.recolor_cape or (r.mode == Recolor.CAPE_SOURCE and (r.scheme or 0) == 0) end

    local function drop(s, frame)
        local card = self.cards[s]
        if not card then return end
        card.controller.restore(frame)
        if card.controller.retired[1] then
            retiring[#retiring + 1] = card.controller
            self.busy = true
        end
        self.cards[s] = nil
    end

    -- New units of a card whose kits and settings are its applied plan's: bound at once; false when it needs a job.
    local function rebind(card, frame)
        local result = card.controller.result
        if card.dirty or not card.applied or not result or not m.records_same(result, card.helmet, card.armor,
            cape_counts(card.settings) and card.cape or nil) then
            return false
        end
        card.controller.apply(result, {units_at = watch.units_at(card.slot), body = card.body}, nil, frame)
        self.rebinds, self.busy = self.rebinds + 1, true
        return true
    end

    local function card_of(s)
        local card = self.cards[s]
        if card then return card end
        card = {slot = s, failures = 0, controller = Recolor.controller({Engine = m.Engine, Avatar = Avatar,
            memory = m.memory, native = m.native, pool = m.pool})}
        self.cards[s] = card
        return card
    end

    -- Slot s shown with owner (a squadmate's key, or false) and status: its card made, kept, rebound, given a job or
    -- dropped.
    local function update(s, owner, status, frame)
        local settings = owner and remote.wanted[owner]
        if not settings then return drop(s, frame) end
        local card = card_of(s)
        local helmet, armor, body, cape = watch.slot_kits(s)
        if card.key ~= owner or not card.settings or not remote.same(card.settings, settings) or helmet ~= card.helmet
            or armor ~= card.armor or body ~= card.body or cape ~= card.cape then
            card.key, card.settings, card.mine = owner, settings, settings == remote.mine
            card.helmet, card.armor, card.body, card.cape = helmet, armor, body, cape
            card.dirty, card.failures, card.applied = true, 0, nil
            self.pending = true
        elseif status == 'units' and not rebind(card, frame) then
            card.dirty, self.pending = true, true
        end
    end

    -- From the UI watch's poll (watch.changes slots showed, changed or went), after a lobby poll (stale) or a clear
    -- (remap): the owners read again when a slot changed, every other player's card kept current. Returns the slot of
    -- the player's own preview, or false when none is shown. own: the Armory's slot (identity.ui_slot); loopback (test
    -- builds): the player's own card goes through this path with its shared value, as another player's would.
    -- The owners read again, logged when they changed.
    local function remap(own)
        self.remap = false
        Lineup.owners(m.read, m.game, Avatar, watch, own, owners)
        local text = owners_text(owners, remote.wanted, remote.mine)
        if text and text ~= logged then note('Squad cards: ' .. text .. '.') end
        logged = text or logged
    end

    function self.observe(frame, w, own, loopback)
        watch = w
        if w.changes > 0 or self.remap then remap(own) end
        self.stale = false
        local mine = false
        for s = 0, SLOTS - 1 do
            local status, owner = w.status(s), owners[s]
            if owner == 'local' and loopback then owner = remote.local_key or false end
            if owner == 'local' and status ~= 'absent' then mine = mine or s end
            if owner == 'local' or status == 'absent' then
                drop(s, frame)
            else
                update(s, owner, status, frame)
            end
        end
        return mine
    end

    -- The next card that needs a job, as a request, or nil (then pending is false), looked for from the card after the
    -- last one served.
    function self.request()
        for step = 1, SLOTS do
            local s = (self.served + step) % SLOTS
            local card = self.cards[s]
            if card and card.dirty and card.failures < Lineup.FAILURE_LIMIT then
                card.dirty, self.served = false, s
                local o = card.settings
                return {target = 'card', slot = s, key = card.key, mode = o.mode, keep_sets = o.keep_sets,
                        keep_hoods = not o.recolor_hoods, materials = o.match_materials, scheme = o.scheme,
                        capes = o.recolor_cape, helmet = card.helmet, armor = card.armor, body = card.body,
                        cape = card.cape}
            end
        end
        self.pending = false
        return nil
    end

    -- A card job's end (ok: it ran without error): applied while the card still wants it (the addon polls the preview
    -- first, so a card that changed meanwhile is dirty and a new job follows).
    function self.finish(ok, result, request, frame)
        local card = self.cards[request.slot]
        if not card or card.key ~= request.key then return end
        if not ok then
            card.failures = card.failures + 1
            card.dirty = card.failures < Lineup.FAILURE_LIMIT
            self.pending = self.pending or card.dirty
            note(string.format('Squad card %s: recolor failed (%d/%d): %s', request.key, card.failures,
                               Lineup.FAILURE_LIMIT, tostring(result)))
            return
        end
        if card.dirty or result.action == 'obsolete' then return end
        local count = card.controller.apply(result, {units_at = watch.units_at(card.slot), body = request.body}, nil,
                                            frame)
        card.applied, self.jobs, self.busy = request, self.jobs + 1, true
        note(string.format('Squad card %s (slot %d): %d materials recolored (%s).', request.key, request.slot, count,
                           result.action == 'apply' and (card.mine and 'your settings' or 'shared settings')
                           or tostring(result.reason)))
    end

    -- One applied card's bindings checked (round robin): a texture the game put back means a new job.
    function self.check()
        for _ = 1, SLOTS do
            cursor = cursor % SLOTS + 1
            local card = self.cards[cursor - 1]
            if card and card.applied then
                if card.controller.probes > 0 and not card.controller.check() then
                    card.dirty, self.pending = true, true
                end
                return
            end
        end
    end

    -- While busy: textures of dropped cards and replaced plans given back after their delay, units not ready at an
    -- apply bound once they are (settle: the addon's, logs as 'Squad card').
    function self.step(frame, settle)
        local busy = false
        if retiring[1] then
            local keep = {}
            for _, c in ipairs(retiring) do
                if c.collect(frame) > 0 then keep[#keep + 1] = c end
            end
            retiring, busy = keep, keep[1] ~= nil
        end
        for _, card in pairs(self.cards) do
            local c = card.controller
            if c.retired[1] then c.collect(frame) end
            if c.pending then settle(c, frame, 'Squad card') end
            busy = busy or c.retired[1] ~= nil or c.pending ~= nil
        end
        self.busy = busy
    end

    -- Every card restored and dropped (the Helldiver lost, pause, stop); the owners read again next time.
    function self.clear(frame)
        for s = 0, SLOTS - 1 do drop(s, frame) end
        self.pending, self.remap, logged = false, true, nil
    end
    return self
end

-- Runs on changes, jobs and checks only: interpreted (no traces in the LuaJIT code cache every mod shares).
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({session_peers, Lineup.session_text, worn, Lineup.owners, owners_text, Lineup.new}) do
        jit.off(fn, true)
    end
end

return Lineup
