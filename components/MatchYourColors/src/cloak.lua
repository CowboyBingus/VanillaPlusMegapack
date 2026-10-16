-- Match Your Colors: Hide Cape (2026-10-16, the user: "a toggle for users to hide their capes if they want", then
-- "include the option to hide everyone's cape as well"; KB match-your-colors-hide-cape). A cape is hidden through the
-- engine's own set_unit_visibility (src/engine.lua native.visibility): one queued command per cape unit, which the
-- unit's world runs in its update; each of the cape's meshes then reads 0 in its visibility mask (Engine.MESH_VISIBILITY,
-- 0xFF while shown). Live on the ship 2026-10-16: hidden at once, still hidden 10 s later, shown again by the reverse
-- call. Helldivers on the ship and in missions only: the Armory's and the loadout screen's figures are other units.
--
-- Targets by key: 'local' (the addon passes its unit watch's refs, no read of its own) and other players ('player
-- <entity id>'): those whose shared value carries the cape_hidden flag (src/sync.lua flag 32), or every other player
-- with Everyone's Capes. A target's cape units are slot 1 of the avatar's three arrays of 10 unit refs; a new one is
-- hidden once, one no longer worn is forgotten (a corpse keeps its hidden cape: the game moves the units into a body
-- copy). The addon calls update on the frame after a lobby poll, step on 1 frame in 4 while other players
-- are targets (one 120-byte read, round robin) and check on its binding check (one 1-byte read: a cape something
-- showed again is hidden again). No memory writes.
local Cloak = {}

Cloak.SLOT, Cloak.ARRAYS = 1, 3
-- The hellpod: the game hides a new mission Helldiver's units 3 frames after it makes them and shows them all again at
-- the pod's exit (live 2026-10-16, no mod but the loader: helmet and cape masks 0xFF -> 0 -> 0xFF, 1,245 frames apart;
-- a ship spawn stays shown). So a new cape is young: its helmet's mask is read every frame (this player's) or on every
-- watch turn (another player's) for GRACE_FRAMES; while that mask is 0 (in the pod) it stays young, up to POD_FRAMES
-- after the hide; when the helmet shows again the cape is hidden again that frame (the binding check alone left it
-- shown up to CHECK_FRAMES frames).
Cloak.GRACE_FRAMES, Cloak.POD_FRAMES = 60, 20000
Cloak.NOTES = 8 -- 'shown again' lines logged at most (the counts go on in the shutdown line)
local NO_UNIT = 0xFFFFFFFF
local DECODED_MAX = 32
local EMPTY = {}

-- m: {Engine, Avatar, Sync, native (src/engine.lua's, with visibility), memory, game, note}.
function Cloak.new(m)
    local Engine, Avatar, native, note = m.Engine, m.Avatar, m.native, m.note
    local read = Avatar.reader(m.memory)
    local u32 = Avatar.u32
    -- young_until: the last frame this player's newest cape is young (the addon's per-frame gate)
    local self = {targets = {}, order = {}, others = {}, cursor = 0, turn = 0, hidden = 0, shown = 0, reshown = 0,
                  young_until = 0}
    local worn = {} -- scratch: the cape units a target wears now

    -- The unit's first mesh (its visibility mask is checked), or 0.
    local function first_mesh(unit)
        if native.meshes(unit) == 0 then return 0 end
        return tonumber(native.mesh(unit, 0)) or 0
    end

    local function whose(key) return key == 'local' and 'your' or (key .. '\'s') end

    -- Target t's young state: until frame (and this player's per-frame gate).
    local function young_until(t, frame)
        t.young_until = frame
        if t.key == 'local' then self.young_until = frame end
    end

    -- A new cape unit hidden; true when it was new.
    local function hide_unit(t, unit, frame)
        if t.capes[unit] or native.alive(unit) == 0 then return false end
        native.visibility(unit, 0, 1)
        t.capes[unit] = first_mesh(unit)
        t.hidden_at, t.pod = frame, false
        young_until(t, frame + Cloak.GRACE_FRAMES)
        self.hidden = self.hidden + 1
        note('Hide Cape: ' .. whose(t.key) .. string.format(' cape hidden (unit %x).', unit))
        return true
    end

    -- Target t's capes: a mask that is not 0 any more (something showed the cape) is hidden again while its unit
    -- lives. One 1-byte read per worn cape (one, as worn).
    -- pod: the hellpod's exit showed it (young_turn), else something else (the binding check); the log tells them apart.
    local function rehide(t, frame, pod)
        for unit, mesh in pairs(t.capes) do
            local b = mesh ~= 0 and read(mesh + Engine.MESH_VISIBILITY, 1)
            if b and b[0] ~= 0 and native.alive(unit) ~= 0 then
                native.visibility(unit, 0, 1)
                self.reshown = self.reshown + 1
                if self.reshown <= Cloak.NOTES then
                    note(string.format(pod and 'Hide Cape: the hellpod opened and showed %s cape %d frames after it was '
                        .. 'hidden; hidden again the next frame.' or 'Hide Cape: the game showed %s cape again %d frames '
                        .. 'after it was hidden; hidden again.', whose(t.key), frame - (t.hidden_at or frame)))
                end
            end
        end
    end

    local function add(key, other)
        local t = {key = key, capes = {}}
        self.targets[key] = t
        self.order[#self.order + 1] = key
        if other then self.others[#self.others + 1] = key end
        return t
    end

    local function remove(list, key)
        for i, k in ipairs(list) do
            if k == key then return table.remove(list, i) end
        end
    end

    -- Target key now wears the cape refs ref(10 * array + SLOT) gives (refs of its 120 unit bytes): new cape units
    -- hidden (young from frame, its helmet, ref 0, the hellpod's sign), units no longer worn forgotten.
    function self.wear(key, ref, other, frame)
        local t = self.targets[key] or add(key, other)
        for unit in pairs(worn) do worn[unit] = nil end
        local fresh = false
        for a = 0, Cloak.ARRAYS - 1 do
            local unit = ref(10 * a + Cloak.SLOT)
            if unit ~= 0 and unit ~= NO_UNIT then
                worn[unit] = true
                fresh = hide_unit(t, unit, frame) or fresh
            end
        end
        for unit in pairs(t.capes) do
            if not worn[unit] then t.capes[unit] = nil end
        end
        if fresh then
            local helmet = ref(0)
            t.helmet_mesh = (helmet ~= 0 and helmet ~= NO_UNIT and native.alive(helmet) ~= 0) and first_mesh(helmet) or 0
        end
    end

    -- A young cape's turn (one 1-byte read): its helmet hidden by the game (the hellpod) keeps it young; the helmet shown
    -- again after that (the pod's exit, which shows the cape too) has it hidden again now; no helmet, no pod.
    local function young_turn(t, frame)
        local b = t.helmet_mesh ~= 0 and read(t.helmet_mesh + Engine.MESH_VISIBILITY, 1)
        if not b then return young_until(t, 0) end
        if b[0] == 0 then
            t.pod = true
            return young_until(t, math.min(frame + Cloak.GRACE_FRAMES, t.hidden_at + Cloak.POD_FRAMES))
        end
        if t.pod then
            t.pod = false
            young_until(t, 0)
            rehide(t, frame, true)
        end
    end

    -- Target key forgotten; show: its capes shown again (those still alive).
    function self.drop(key, show)
        local t = self.targets[key]
        if not t then return end
        if show then
            for unit in pairs(t.capes) do
                if native.alive(unit) ~= 0 then
                    native.visibility(unit, 1, 1)
                    self.shown = self.shown + 1
                end
            end
            note('Hide Cape: ' .. whose(key) .. ' cape shown again.')
        end
        self.targets[key] = nil
        remove(self.order, key)
        remove(self.others, key)
    end

    -- Every target dropped and its capes shown (the choice off with no sharer, a pause, a stop).
    function self.clear()
        while self.order[1] do self.drop(self.order[1], true) end
    end

    -- The binding check's turn: one target's capes (round robin over every target) hidden again if shown.
    function self.check(frame)
        local n = #self.order
        if n == 0 then return end
        self.turn = self.turn % n + 1
        rehide(self.targets[self.order[self.turn]], frame)
    end

    -- Every frame while this player's cape is young (the addon's second check on such frames): the pod's exit has it
    -- hidden again the frame after the game showed it.
    function self.young(frame)
        local t = self.targets['local']
        if not t or frame > (t.young_until or 0) then return false end
        young_turn(t, frame)
        return true
    end

    -- Another player's unit refs from the last step's read.
    local current
    local function current_ref(i) return u32(current, 4 * i) end

    -- 1 frame in 4 (src/addon.lua) while other players are targets: one of them (round robin) has its 120 unit bytes read;
    -- other cape units than it wears are hidden; a young cape of theirs has its helmet read (one more read: the pod).
    function self.step(frame)
        local n = #self.others
        if n == 0 then return end
        self.cursor = self.cursor % n + 1
        local t = self.targets[self.others[self.cursor]]
        local b = t.units_at and read(t.units_at, Avatar.UNIT_BYTES)
        if not b then return end
        for a = 0, Cloak.ARRAYS - 1 do
            local unit = u32(b, 40 * a + 4 * Cloak.SLOT)
            if unit ~= 0 and unit ~= NO_UNIT and not t.capes[unit] then
                current = b
                return self.wear(t.key, current_ref, true, frame)
            end
        end
        if frame <= (t.young_until or 0) then young_turn(t, frame) end
    end

    -- A member's value: whether it hides its cape (decoded once per text).
    local decoded, decoded_count = {}, 0
    local function hides(text)
        if text == nil then return false end
        local h = decoded[text]
        if h == nil then
            if decoded_count >= DECODED_MAX then decoded, decoded_count = {}, 0 end
            local o = m.Sync.decode(text)
            h = (o and o.cape_hidden) == true
            decoded[text], decoded_count = h, decoded_count + 1
        end
        return h
    end

    local function wanted_player(p, members, everyone)
        if p['local'] then return false end
        if everyone then return true end
        for _, member in ipairs(members) do
            if not member['local'] and member.peer_low == p.peer_low and member.peer_high == p.peer_high then
                return hides(member.text)
            end
        end
        return false
    end

    -- A wanted player: their Helldiver resolved once per Helldiver unit (its unit bytes), their capes hidden.
    local function follow(p, seen, frame)
        local key = 'player ' .. p.player
        seen[key] = true
        local t = self.targets[key]
        if t and t.unit == p.unit then return end
        local identity = Avatar.resolve_remote(read, m.game, p, {})
        local b = identity and read(identity.units_at, Avatar.UNIT_BYTES)
        if not b then return end
        current = b
        self.wear(key, current_ref, true, frame)
        t = self.targets[key]
        t.unit, t.units_at = p.unit, identity.units_at
    end

    -- Whether a member other than this player hides their cape (no read).
    local function any_hides(members)
        for _, member in ipairs(members) do
            if not member['local'] and hides(member.text) then return true end
        end
        return false
    end

    -- Whether update has work after a poll (no read): someone's cape to hide here, or other players' hidden now.
    function self.needed(members, everyone)
        return everyone or self.others[1] ~= nil or any_hides(members or EMPTY)
    end

    -- From a lobby poll (the frame after it): members {{peer_low, peer_high, text, local}, ...} or nil; everyone: every
    -- other player's cape is hidden here (Everyone's Capes), else those of members whose value hides it. The players
    -- are read only when someone's cape is to be hidden.
    local seen = {}
    function self.update(members, everyone, frame)
        members = members or EMPTY
        local any = everyone or any_hides(members)
        for key in pairs(seen) do seen[key] = nil end
        if any then
            for _, p in ipairs(Avatar.players(read, m.game)) do
                if wanted_player(p, members, everyone) then follow(p, seen, frame) end
            end
        end
        for i = #self.others, 1, -1 do
            local key = self.others[i]
            if not seen[key] then self.drop(key, true) end
        end
    end
    return self
end

-- Runs on option changes, unit changes, lobby polls and 1 frame in 4: interpreted (no traces in the LuaJIT
-- code cache every mod shares).
if type(jit) == 'table' and type(jit.off) == 'function' then jit.off(Cloak.new, true) end

return Cloak
