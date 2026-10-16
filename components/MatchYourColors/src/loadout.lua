-- Match Your Colors: Recolor Weapons for the local Helldiver (v1.5; KB match-your-colors-weapons). Its weapons
-- (src/weapons.lua: primary, sidearm, support weapon and their attachments) are a target of their own beside the
-- avatar and the UI preview: a controller of their own binds pooled textures to their units, planned against the
-- mode's source as the cape is (src/recolor.lua Recolor.weapons_job).
--
-- Checks, only while Recolor Weapons is on and something local is recolored (src/addon.lua):
--   * every frame while a weapon is in hand and recolored: one 8-byte read of one of its materials' LUT binding. The
--     game binds the weapon's paint again whenever it reloads (static research: 0x11c1be0 -> 0x749dd0, every unit of
--     the weapon in hand; the magazine is a new unit), after the mods' update: the recolor is bound again on the next
--     frame, so a reload shows the weapon's own colors for one frame. A second check per frame beside the avatar's:
--     a slower one would show them for longer on every reload;
--   * 1 frame in ROW_FRAMES (frame % ROW_FRAMES == ROW_PHASE: never the UI gate's or the remote watch's frame): one
--     48-byte read of the inventory row (the weapons held, a pickup, the slot in hand);
--   * a change: the weapons resolved again (about 15 reads each); the same weapons and paints are bound again at once
--     (a new mission, a respawn, a pickup of the same weapon, a reload), others need a job.
-- Another mod user's weapons (src/remote.lua) are read on their watch turn instead; as the game moves rows, their row
-- is checked to be still theirs (2 reads) on a change and on their binding check, and found again when it moved.
-- No allocation on frames without a change.
local ffi = require('ffi')

local Loadout = {}

Loadout.ROW_FRAMES, Loadout.ROW_PHASE = 4, 2
local HIGH = 4294967296

-- m: {Weapons, Recolor, Engine, Avatar, memory, native, pool, game, read (Avatar.reader), note, follow (another mod
-- user's weapons, src/remote.lua: their row checked, moved below; its log name, 'Sync: <peer>')}.
function Loadout.new(m)
    local Weapons, Engine, Avatar = m.Weapons, m.Engine, m.Avatar
    local controller = m.Recolor.controller({Engine = Engine, Avatar = Avatar, memory = m.memory, native = m.native,
        pool = m.pool, units = function(identity) return Weapons.units(identity.list) end})
    local copy = ffi.new('uint8_t[?]', Weapons.COPY_SPAN)
    local small, wide = ffi.new('uint8_t[16]'), ffi.new('uint8_t[1024]')
    local scratch = m.follow and ffi.new('uint8_t[?]', Weapons.HEAD_BYTES) or nil
    local POINTER = ffi.typeof('const uint8_t *')
    local function read_into(address, size, out) return m.memory.read_into(ffi.cast(POINTER, address), size, out) end
    -- the Armory's weapon preview (Weapons.preview, slot 3): a controller of its own, planned for the weapon and
    -- customization it shows
    local shown = m.Recolor.controller({Engine = Engine, Avatar = Avatar, memory = m.memory, native = m.native,
        pool = m.pool, units = function(identity) return Weapons.units(identity.list) end})
    local self = {controller = controller, shown_controller = shown, where = nil, watch = nil, resolved = nil,
                  dirty = false, changed = false, reload = false, entry = nil, low = 0, high = 0, rebinds = 0,
                  reloads = 0, jobs = 0, sig = nil, preview = nil, preview_dirty = false, previews = 0, moves = 0}

    -- What the weapons' plan depends on: each slot's weapon name and paint (src/weapons.lua decode_copy texts).
    local function signature(resolved)
        local parts = {}
        for slot = 1, 3 do
            local w = resolved and resolved.list[slot]
            if w then
                local texts = {}
                for role = 0, 4 do
                    local o = w.overrides[role]
                    texts[#texts + 1] = (w.attachments[role] or '') .. '=' .. (o and o.text or '')
                end
                parts[#parts + 1] = slot .. ':' .. w.name .. ':' .. table.concat(texts, ';')
            end
        end
        return table.concat(parts, '|')
    end

    -- The weapon in hand's LUT binding to watch (its main unit's first bound LUT slot), from the last apply.
    local function watch_entry()
        self.entry = nil
        local r = self.resolved
        local held = r and r.list[r.held]
        if not held then return end
        for _, b in ipairs(controller.bindings) do
            if b.unit == held.unit and b.slot == Engine.LUT_SLOT then
                local entry = Engine.binding_entry(read_into, b.material, Engine.LUT_SLOT, small, wide)
                if entry then
                    self.entry, self.low, self.high = entry, b.texture % HIGH, math.floor(b.texture / HIGH)
                end
                return
            end
        end
    end

    -- Binds the current result to the resolved weapons' units (a respawn, a new mission, a reload): bindings made.
    local function rebind(frame)
        local count = controller.apply(controller.result, {list = self.resolved.list}, nil, frame)
        self.rebinds = self.rebinds + 1
        watch_entry()
        return count
    end

    -- A new local Helldiver (src/addon.lua adopt; another mod user's new avatar, src/remote.lua): its inventory row
    -- located; the next step resolves its weapons.
    function self.adopt(identity)
        self.where = Weapons.locate(m.read, Avatar.lookup, m.game, identity.avatar, m.follow)
        self.watch = self.where and Weapons.watch(m.memory, self.where) or nil
        self.entry, self.changed = nil, self.watch ~= nil
        controller.prune()
    end

    -- Another mod user's row (m.follow): the game moves rows when an avatar is removed (src/weapons.lua), so the row
    -- found at adopt can hold another player's weapons (a squad of four, 2026-10-16: five 'weapons recolored, 0
    -- materials' jobs planned weapons other players' recolors held) while theirs change unseen elsewhere. True when it
    -- is not their avatar's any more: located again (read on their next turn), or none while the avatar has none
    -- (dead: their respawn adopts its new one). 2 reads (Weapons.owned). Located again where it was, the check misread
    -- the inventory (another game build): it stops for this row, noted, so it cannot locate the row every check. Each
    -- outcome is noted (a few lines per death in a squad: the evidence a squad test reads).
    local function moved()
        if not (scratch and self.where) or Weapons.owned(m.memory, self.where, scratch) then return false end
        local before = self.where
        self.moves = self.moves + 1
        self.adopt(before)
        local now = self.where
        if not now then
            m.note(m.follow .. ' weapons: their row is another Helldiver\'s now and they have none (dead or gone); '
                   .. 'found again when they are back.')
        elseif now.row == before.row and now.owner == before.owner then
            now.owner = nil
            m.note(m.follow .. ' weapons: their row read as moved but was not (the inventory reads differently); '
                   .. 'it is no longer checked.')
        else
            m.note(string.format('%s weapons: the game moved their row (%d -> %d); found again.', m.follow,
                                 before.index, now.index))
        end
        return true
    end

    -- Recolor Weapons off, the Helldiver lost, a pause or stop: the weapons' own colors back, nothing watched.
    function self.clear(frame)
        controller.restore(frame)
        shown.restore(frame)
        self.where, self.watch, self.resolved, self.entry, self.sig = nil, nil, nil, nil, nil
        self.dirty, self.changed, self.reload, self.preview, self.preview_dirty = false, false, false, nil, false
    end

    -- A new plan is due (options, kits or the source changed): the next job slot plans the weapons again, and the
    -- Armory's preview weapon while one is shown (live 2026-10-15: mode changes left the preview in its first plan).
    function self.replan()
        if self.watch then self.dirty, self.changed = true, true end
        if self.preview then self.preview_dirty = true end
    end

    -- The resolve after a change: the same weapons and paints bound again at once, others a job. Another mod user's
    -- changed row is first checked to be still theirs (moved).
    local function settle(frame)
        if self.changed and moved() then return end
        local resolved = Weapons.resolve(m.read, Avatar.lookup, m.game, self.where, m.memory, copy)
        if not resolved then return end
        local sig = signature(resolved)
        self.resolved = resolved
        if self.reload then self.reloads = self.reloads + 1 end
        self.changed, self.reload = false, false
        if sig == '' then -- no weapon (dead, or a loadout without any): nothing bound, nothing to watch
            self.entry = nil
            return
        end
        if sig ~= self.sig or not controller.result or self.dirty then
            self.dirty, self.pending_sig = true, sig
            return
        end
        rebind(frame)
    end

    -- Every frame while on (busy: the avatar's chain check ran this frame; a resolve waits a frame then; every: the row
    -- read on this call whatever the frame, another mod user's watch turn, src/remote.lua). True when it resolved.
    function self.step(frame, busy, every)
        local watch = self.watch
        if not watch then return false end
        if self.entry and not watch.bound(self.entry, self.low, self.high) then self.reload = true end
        if (every or frame % Loadout.ROW_FRAMES == Loadout.ROW_PHASE) and watch.row_changed() then self.changed = true end
        if busy or not (self.changed or self.reload) then return false end
        settle(frame)
        return true
    end

    -- The weapons' request for a job (src/addon.lua adds the options and kits), or nil when none is due.
    function self.request()
        if not self.dirty or not self.resolved then return nil end
        self.dirty = false
        local list = {}
        for slot = 1, 3 do
            if self.resolved.list[slot] then list[#list + 1] = self.resolved.list[slot] end
        end
        if #list == 0 then return nil end -- no weapon held (dead): nothing to plan
        return {weapons = list, sig = self.pending_sig or signature(self.resolved)}
    end

    -- A finished weapons job: applied when the weapons are still the ones planned (the bindings it made), else nil and
    -- a new job follows.
    function self.finish(result, request, frame)
        self.jobs = self.jobs + 1
        if request.sig ~= signature(self.resolved) then
            self.dirty = true
            return nil
        end
        local count = controller.apply(result, {list = self.resolved.list}, nil, frame)
        self.sig = result.action == 'apply' and request.sig or nil
        watch_entry()
        return count
    end

    -- Every CHECK_FRAMES frames: one recolored material per texture still holds its texture (an optic's spawn binds
    -- the underbarrel's paint again two frames later; static research); another mod user's row still theirs (moved:
    -- their row moved away leaves its old bytes, which then never change).
    function self.check(frame)
        if controller.probes > 0 and not controller.check() and controller.result and self.resolved then
            rebind(frame)
        end
        if shown.probes > 0 then self.check_shown(frame) end
        moved()
    end

    function self.collect(frame)
        if controller.retired[1] then controller.collect(frame) end
        if shown.retired[1] then shown.collect(frame) end
    end

    -- The Armory's weapon preview, read again after the UI gate saw its ring head move (the game spawned or updated a
    -- preview weapon: another weapon, an attachment, a paint scheme): the same weapon and customization bound again at
    -- once, another a job (preview_dirty), none (closed) its textures retired. Also read when an option changes while
    -- none is tracked (src/addon.lua weapons_option: Recolor Weapons turned on in the Armory); a slot whose unit is
    -- not alive (left from an earlier Armory visit) shows none.
    function self.preview_changed(frame)
        local now = Weapons.preview(m.read, m.game)
        if now and m.native.alive(now.unit) == 0 then now = nil end
        if not now then
            if self.preview then shown.restore(frame) end
            self.preview, self.preview_dirty = nil, false
            return
        end
        local applied = self.preview and self.preview.applied
        self.preview = {now = now, applied = applied}
        if applied == now.key and shown.result then
            shown.apply(shown.result, {list = {now}}, nil, frame)
        else
            self.preview_dirty = true
        end
    end

    -- The preview weapon's request (src/addon.lua adds the options and kits), or nil.
    function self.preview_request()
        local p = self.preview
        if not self.preview_dirty or not p then return nil end
        self.preview_dirty = false
        local w = {id = 0, name = p.now.name, unit = p.now.unit, units = p.now.units, ids = p.now.ids, overrides = {},
                   attachments = {}}
        return {weapons = {w}, sig = p.now.key}
    end

    -- A finished preview job: applied when the preview still shows that weapon and customization.
    function self.finish_preview(result, request, frame)
        local now = Weapons.preview(m.read, m.game)
        if not now or now.key ~= request.sig then
            self.preview_changed(frame)
            return 0
        end
        self.previews = self.previews + 1
        local count = shown.apply(result, {list = {now}}, nil, frame)
        self.preview = {now = now, applied = result.action == 'apply' and now.key or nil}
        return count
    end

    -- The preview's textures given back when its units are gone (the Armory closed without another preview).
    local function check_shown(frame)
        local b = shown.bindings[1]
        if b and m.native.alive(b.unit) == 0 then
            shown.restore(frame)
            self.preview = nil
        end
    end
    self.check_shown = check_shown

    -- Everything but the per-frame step runs on changes only: interpreted (no traces in the code cache every mod
    -- shares).
    if type(jit) == 'table' and type(jit.off) == 'function' then
        for _, fn in ipairs({signature, watch_entry, rebind, self.adopt, moved, self.clear, self.replan, settle,
                             self.request,
                             self.finish, self.check, self.collect, read_into, self.preview_changed,
                             self.preview_request, self.finish_preview, check_shown}) do
            jit.off(fn, true)
        end
    end
    return self
end

return Loadout
