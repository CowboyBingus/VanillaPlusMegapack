-- Match Your Colors: other mod users' Helldivers (Sync With Mod Users). From each sync poll (src/sync.lua), every
-- other player who shares valid settings gets an entry: their player record and kits (src/avatar.lua), a watch of
-- their 120 bytes of unit refs, and a controller of their own that binds pooled textures to their units
-- (src/recolor.lua). Their jobs run in the addon's single job slot, after the local avatar and UI preview. An entry
-- is restored and dropped when its player leaves, stops sharing or shares something unreadable.
--
-- The addon calls step on 1 frame in WATCH_FRAMES and check every CHECK_FRAMES frames, only while an entry exists
-- (or textures retire): step checks one entry's units (one 120-byte read, round robin) and hands textures of dropped
-- entries back to the pool after their retire delay; check reads one entry's bindings. pending: an entry waits
-- for a job.
local Remote = {}

Remote.FAILURE_LIMIT, Remote.WATCH_FRAMES = 3, 4
local EMPTY = {}

-- m: {Avatar, Recolor, Engine, Sync, memory, native, pool, game, read (Avatar.reader), note}.
function Remote.new(m)
    local Avatar, Recolor, Sync = m.Avatar, m.Recolor, m.Sync
    local self = {entries = {}, order = {}, retiring = {}, cursor = 0, jobs = 0, pending = false}

    local function key_of(member) return string.format('%08x%08x', member.peer_high, member.peer_low) end

    local function same(a, b)
        return a.mode == b.mode and a.keep_sets == b.keep_sets and a.recolor_hoods == b.recolor_hoods
            and a.match_materials == b.match_materials and a.recolor_cape == b.recolor_cape and a.scheme == b.scheme
    end

    local function add(key)
        local e = {key = key, failures = 0, controller = Recolor.controller({Engine = m.Engine, Avatar = Avatar,
            memory = m.memory, native = m.native, pool = m.pool})}
        self.entries[key] = e
        self.order[#self.order + 1] = key
        return e
    end

    local function drop(key, frame)
        local e = self.entries[key]
        e.controller.restore(frame)
        if e.controller.retired[1] then self.retiring[#self.retiring + 1] = e.controller end
        self.entries[key] = nil
        for i, k in ipairs(self.order) do
            if k == key then table.remove(self.order, i) break end
        end
        m.note('Sync: ' .. key .. ' restored.')
    end

    -- The player of a member (by peer id), or nil; the local player only for the local member (the loopback).
    local function player_of(players, member)
        for _, p in ipairs(players) do
            if p.peer_low == member.peer_low and p.peer_high == member.peer_high
                and (not p['local'] or member['local']) then
                return p
            end
        end
        return nil
    end

    -- One member's settings into its entry (a new one when needed); its key, or nil when it has no Helldiver here
    -- (noted once until it has one: a lobby member whose peer id names no player here, the first two-player test's
    -- question, 2026-10-07).
    local unmatched = {}
    local function take(players, member, settings)
        local player = player_of(players, member)
        local key = key_of(member)
        if not player then
            if not unmatched[key] then
                unmatched[key] = true
                m.note('Sync: ' .. key .. ' shares settings; no Helldiver of theirs found here yet.')
            end
            return nil
        end
        unmatched[key] = nil
        local e = self.entries[key] or add(key)
        if not e.settings or not same(e.settings, settings) or e.player.unit ~= player.unit then
            e.settings, e.player, e.dirty, e.failures = settings, player, true, 0
            self.pending = true
        end
        return key
    end

    -- A member's settings: values decoded once (the same text comes every poll), false for an unreadable one.
    local decoded, decoded_count = {}, 0
    local function settings_of(text)
        if text == nil then return false end
        local settings = decoded[text]
        if settings == nil then
            if decoded_count >= 32 then decoded, decoded_count = {}, 0 end
            settings = Sync.decode(text) or false
            decoded[text], decoded_count = settings, decoded_count + 1
        end
        return settings
    end

    -- From a sync poll: members {{peer_low, peer_high, text, local}, ...}, or nil (no lobby, or sharing off). The
    -- players are read only when a member shares a readable value. seen and gone are reused.
    local seen, gone = {}, {}
    function self.update(frame, members)
        local players
        for key in pairs(seen) do seen[key] = nil end
        for _, member in ipairs(members or EMPTY) do
            local settings = settings_of(member.text)
            if settings then
                players = players or Avatar.players(m.read, m.game)
                local key = take(players, member, settings)
                if key then seen[key] = true end
            end
        end
        for i = #gone, 1, -1 do gone[i] = nil end
        for key in pairs(self.entries) do
            if not seen[key] then gone[#gone + 1] = key end
        end
        for _, key in ipairs(gone) do drop(key, frame) end
    end

    -- The next entry that needs a job, as a request, or nil (then pending is false). Its player is resolved again
    -- first (kits, avatar).
    function self.request()
        for _, key in ipairs(self.order) do
            local e = self.entries[key]
            if e.dirty and e.failures < Remote.FAILURE_LIMIT then
                e.dirty = false
                local identity, why = Avatar.resolve_remote(m.read, m.game, e.player, {})
                if identity then
                    e.identity, e.watch = identity, Avatar.watch(m.memory, identity, nil)
                    e.watch.changed() -- keeps the current units
                    local s = e.settings
                    return {target = 'remote', key = key, mode = s.mode, keep_sets = s.keep_sets,
                            keep_hoods = not s.recolor_hoods, materials = s.match_materials, scheme = s.scheme,
                            capes = s.recolor_cape, helmet = identity.helmet, armor = identity.armor,
                            body = identity.body, cape = identity.cape}
                end
                e.failures = e.failures + 1
                m.note('Sync: ' .. key .. ' not resolved (' .. tostring(why) .. ').')
            end
        end
        self.pending = false
        return nil
    end

    -- A job's end for request (ok: it ran without error). Applied when the entry still wants it.
    function self.finish(ok, result, request, frame)
        local e = self.entries[request.key]
        if not e then return end
        if not ok then
            e.failures = e.failures + 1
            e.dirty = e.failures < Remote.FAILURE_LIMIT
            self.pending = self.pending or e.dirty
            m.note('Sync: recolor of ' .. request.key .. ' failed (' .. e.failures .. '/' .. Remote.FAILURE_LIMIT
                   .. '): ' .. tostring(result))
            return
        end
        if e.dirty then return end -- its settings or units changed while the job ran: a new job follows
        local count = e.controller.apply(result, e.identity, nil, frame)
        self.jobs = self.jobs + 1
        m.note(string.format('Sync: %s recolored, %d materials (%s).', request.key, count,
                             result.action == 'apply' and 'shared settings' or tostring(result.reason)))
    end

    -- One entry's units checked (round robin; a change wants a job), retired textures collected.
    function self.step(frame)
        if self.retiring[1] then
            local keep = {}
            for _, c in ipairs(self.retiring) do
                if c.collect(frame) > 0 then keep[#keep + 1] = c end
            end
            self.retiring = keep
        end
        local n = #self.order
        if n == 0 then return end
        self.cursor = self.cursor % n + 1
        local e = self.entries[self.order[self.cursor]]
        if e.controller.retired[1] then e.controller.collect(frame) end
        if e.watch and e.watch.changed() then
            e.dirty = true
            self.pending = true
        end
    end

    -- One entry's recolored materials still hold their textures (the entry the next step checks).
    function self.check()
        local n = #self.order
        if n == 0 then return end
        local e = self.entries[self.order[(self.cursor % n) + 1]]
        if e.controller.probes > 0 and not e.controller.check() then
            e.dirty = true
            self.pending = true
        end
    end

    -- Every entry restored and dropped (sharing off, pause, stop).
    function self.clear(frame)
        local keys = {}
        for key in pairs(self.entries) do keys[#keys + 1] = key end
        for _, key in ipairs(keys) do drop(key, frame) end
        self.pending = false
    end
    return self
end

-- Runs on sync polls, jobs and 1 frame in WATCH_FRAMES: interpreted (no traces in the LuaJIT code cache every mod
-- shares; the addon's per-frame gate stays compiled).
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(Remote.new, true) end

return Remote
