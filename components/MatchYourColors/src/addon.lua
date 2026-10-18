-- Match Your Colors: startup checks, the per-frame step, Mod Options Menu settings and the log.
--
-- Every frame, before the game's update (Bingus Shared Runtime's guard):
--   * no local Helldiver yet (title screen, loading, dead): one resolve every RESOLVE_FRAMES frames; while a world
--     loads, the first job's work is done ahead in a job of its own (plan_ahead: the pipeline, then the plans of the
--     kits the player will wear), so the Helldiver's own job is about one frame;
--   * idle: one read of the Helldiver's 120 unit bytes, plus one of its preview slot's entry count (and
--     entries while there are any); nothing else unless they changed;
--   * the UI preview of the local player (the Armory CHARACTER view, src/preview.lua): on 1 frame in UI_GATE_FRAMES
--     while it is not shown, one 16-byte read of the preview system's gate while no player slot shows (else the
--     player slots' span, 1,296 bytes), the span every frame while it is shown; a change of the kits it shows starts a
--     job for that pair (its own textures and bindings);
--   * every VERIFY_FRAMES frames the whole local-player chain is resolved again;
--   * every CHECK_FRAMES frames one recolored material per runtime texture is read (two reads each): if the
--     game put its original LUT back, the recolor is applied again;
--   * a change (re-equip, respawn, a preview, an option) starts a job; a running job gets BUDGET seconds of
--     work per frame and its result is applied in one frame, refilling pooled textures (src/engine.lua pool; making
--     a texture waits for the render thread, so new ones are made while the game loads, or when the pool has none of
--     the size); the game-data reader a job opened stays open while the UI preview is shown, else until the next
--     binding check without a job (release_reader);
--   * new analyses go to the disk cache in a save job of its own (BUDGET per frame) once no recolor job runs and
--     the UI preview has been closed for SAVE_DELAY_FRAMES frames, at shutdown at the latest;
--   * Recolor Weapons (src/loadout.lua, v1.5): while on, one 8-byte read per frame of the weapon in hand's LUT
--     binding (a reload binds its own paint again) and the inventory row on 1 frame in 4; the weapons a job of their own;
--   * Sync With Mod Users (src/sync.lua, src/remote.lua; always on, no option since 2026-10-07): every
--     Sync.POLL_FRAMES frames the squad's PlayFab lobby is read (and this player's settings posted when due); while
--     other mod users' Helldivers are recolored, one of them has its units checked per frame (round robin) and one
--     its bindings every CHECK_FRAMES frames;
--   * Hide Cape (src/cloak.lua, 2026-10-16): the local cape hidden on the frames the unit watch reports a change (no
--     read of its own), one hidden cape's mask read on the binding check; other players' capes: the players read on
--     the frame after a lobby poll while any is to be hidden, then one of them has its units read on 1 frame in 4.
-- No memory writes: the recolor goes through engine calls (src/engine.lua).
local ffi = require('ffi')

local Addon = {VERSION = '1.5'}
Addon.REVISION = 'v' .. Addon.VERSION
Addon.MOD_ID = 'cowboybingus.match_your_colors'
Addon.OPTION_MODE = 'cowboybingus.match_your_colors.mode'
Addon.OPTION_SCHEME = 'cowboybingus.match_your_colors.paint_scheme'
Addon.OPTION_SETS = 'cowboybingus.match_your_colors.keep_sets'
Addon.OPTION_HOODS = 'cowboybingus.match_your_colors.recolor_hoods'
Addon.OPTION_MATERIALS = 'cowboybingus.match_your_colors.match_materials'
Addon.OPTION_CAPES = 'cowboybingus.match_your_colors.recolor_cape'
Addon.OPTION_SQUAD = 'cowboybingus.match_your_colors.recolor_squadmates'
Addon.OPTION_WEAPONS = 'cowboybingus.match_your_colors.recolor_weapons'
-- Recolor Squadmates' values (the menu's choice index): off, squadmates without the mod take this player's settings,
-- every squadmate takes them (v1.5; never shared: other players' sync values stay v1.4's)
Addon.SQUAD_OFF, Addon.SQUAD_MISSING, Addon.SQUAD_EVERYONE = 1, 2, 3
-- Squadmates' Colors (2026-10-16, the user: "make their color scheme match the players' as well"): those squadmates'
-- own gear matched with this player's Color Matching, or their gear in this player's colors (the mode's source item).
Addon.OPTION_SQUAD_COLORS = 'cowboybingus.match_your_colors.squadmates_colors'
Addon.SQUAD_OWN, Addon.SQUAD_YOURS = 1, 2
-- Hide Cape (2026-10-16, src/cloak.lua): off, this player's cape (shared: squadmates with the mod hide it too), or every
-- Helldiver's cape on this screen.
Addon.OPTION_HIDE_CAPE = 'cowboybingus.match_your_colors.hide_cape'
Addon.HIDE_OFF, Addon.HIDE_YOURS, Addon.HIDE_EVERYONE = 1, 2, 3
Addon.RESOLVE_FRAMES = 15
Addon.VERIFY_FRAMES = 120
Addon.CHECK_FRAMES = 30
Addon.UI_GATE_FRAMES = 4
Addon.BUDGET = 0.0015
Addon.APPLY_ALONE = 0.0002 -- a job's last slice longer than this: its result is applied on the next frame (run_job)
Addon.SAVE_DELAY_FRAMES = 300
Addon.KEEP_FRAMES = 600
Addon.CLOSES_PER_CHECK = 4 -- queued game-file handles closed per binding check (close_kept: about 0.09 ms each in game)
Addon.FAILURE_LIMIT = 3
Addon.REGISTER_FRAMES = {1, 60, 180, 420, 900, 1800}
Addon.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
Addon.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
Addon.MODE_NAMES = {'off', 'helmet matches armor', 'armor matches helmet', 'helmet and armor match the cape'}

-- Whether two identities name the same Helldiver with the same kits and records (the cape aside: it matters only
-- with Recolor Cape on or the cape as the source, see verify).
local function same_identity(a, b)
    return a.units_at == b.units_at and a.avatar == b.avatar and a.helmet == b.helmet and a.armor == b.armor
        and a.body == b.body and a.peer_low == b.peer_low and a.peer_high == b.peer_high and a.ui_slot == b.ui_slot
end

-- Whether a loading Helldiver's applied kits are real: its record shows stand-ins (0xffffffff) first, live 2026-10-08
-- on the ship: the helmet, then the armor some frames later, the Helldiver itself about 1.4 s after both. capes: the
-- cape counts (Recolor Cape on, or Helmet and Armor Match Cape).
local STAND_IN = 0xffffffff
local function real_kits(k, capes)
    return (k.helmet or 0) ~= 0 and (k.armor or 0) ~= 0 and k.helmet ~= STAND_IN and k.armor ~= STAND_IN
        and not (capes and k.cape == STAND_IN)
end

-- The log's '; N frames after the Helldiver was found' (the first result after it was found), else ''.
local function after_text(after)
    if not after then return '' end
    return string.format('; %d %s after the Helldiver was found', after, after == 1 and 'frame' or 'frames')
end

-- Hide Cape's capes hidden on this screen (src/cloak.lua), or nil without the module or the engine's visibility call.
local function new_cloak(m)
    if not (m.Cloak and m.native.visibility) then return nil end
    return m.Cloak.new({Engine = m.Engine, Avatar = m.Avatar, Sync = m.Sync, native = m.native, memory = m.memory,
                        game = m.game, note = m.note})
end

-- The instance: step() every frame, pause(reason), stopped(reason), set_option(name, value).
-- m: the modules and services {Avatar, Preview, Recolor, Engine, Files, Slim, Texture, Colour, Transfer, Matcher,
-- Kits, Schemes, Patches, Sync, Remote, memory, native, game, note, natives (PlayFab's, default Sync.natives)}; without
-- Preview
-- there is no UI preview target, without Sync and Remote no sync.
function Addon.new(m)
    local Avatar, Preview, Recolor, memory, note = m.Avatar, m.Preview, m.Recolor, m.memory, m.note
    local time = memory.time
    -- active: the local player's items or preview can be recolored (Color Matching on, or a paint scheme); off, the
    -- per-frame watch reads the units alone (set_option keeps it current).
    local state = {frame = 0, next_resolve = 0, next_verify = 0, next_check = 0, identity = nil, watch = nil, slot = nil,
                   dirty = false, job = nil, request = nil, failures = {}, why = nil, budget_end = 0,
                   options = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, recolor_hoods = true,
                              match_materials = false, recolor_cape = false, recolor_weapons = false, scheme = 0,
                              squad = Addon.SQUAD_OFF, squad_colors = Addon.SQUAD_OWN, hide_cape = Addon.HIDE_OFF,
                              cape_hidden = false},
                   next_sync = 0, loopback = false, holder = {}, status = 'starting', active = true}
    local pool = m.Engine.pool({native = m.native, memory = memory})
    local controller = Recolor.controller({Engine = m.Engine, Avatar = Avatar, memory = memory, native = m.native,
                                           pool = pool})
    -- The UI preview's units are other units than the avatar's, showing maybe another pair: own textures and
    -- bindings, from the same pool.
    local ui_controller = Recolor.controller({Engine = m.Engine, Avatar = Avatar, memory = memory, native = m.native,
                                              pool = pool})
    local read = Avatar.reader(memory) -- one buffer for every resolve
    local probe = {} -- the identity table every check refills; adopted identities are copies
    -- wait: a game-data read the disk has not answered yet lets the job sit out a frame (src/files.lua).
    local job_deps = {Files = m.Files, Slim = m.Slim, Patches = m.Patches, Texture = m.Texture, Colour = m.Colour,
                      Albedo = m.Albedo, Weapons = m.Weapons, WeaponData = m.WeaponData, Avatar = Avatar,
                      Transfer = m.Transfer, Matcher = m.Matcher, Kits = m.Kits, Schemes = m.Schemes, Capes = m.Capes,
                      memory = memory, wait = coroutine.yield,
                      game = m.game,
                      Cache = m.Cache, Appearance = m.Appearance,
                      cache_path = m.cache_path,
                      build = {exe_sha256 = Addon.EXE_SHA256, game_sha256 = Addon.GAME_SHA256}}
    -- Whether a result was made of the kit records as they read now (signatures, src/recolor.lua): a transmog mod
    -- recomposes a record at runtime under the same id (its carrier; KB match-your-colors-review-transmog-v13), and the
    -- new units then show other pieces. Read through the job's catalogue (no pause); without one, false.
    local function record_same(kits, signatures, id)
        return not id or id == 0 or (signatures[id] ~= nil and kits.signature(id) == signatures[id])
    end
    local function records_same(result, helmet, armor, cape)
        local p = state.holder.pipeline
        local kits, signatures = p and p.kits, result.signatures
        if not (kits and signatures) then return false end
        return record_same(kits, signatures, helmet) and record_same(kits, signatures, armor)
            and record_same(kits, signatures, cape)
    end

    -- Sync With Mod Users: the lobby session and the other players' recolors. Always on (the user, 2026-10-07: no
    -- option, every mod user shares and sees the others): this player's settings are shared from the start.
    local session = m.Sync and m.Remote and m.Sync.session({memory = memory, game = m.game, note = note,
                                                            natives = m.natives or m.Sync.natives})
    local remote = session and m.Remote.new({Avatar = Avatar, Recolor = Recolor, Engine = m.Engine, Sync = m.Sync,
                                             memory = memory, native = m.native, pool = pool, game = m.game,
                                             read = Avatar.reader(memory), note = note, records_same = records_same,
                                             Loadout = m.Weapons and m.Loadout, Weapons = m.Weapons})
    -- The squad cards of the loadout screen, each in its player's settings, and the slot of the player's own preview
    -- among them (src/lineup.lua).
    local lineup = remote and m.Lineup and m.Lineup.new({Avatar = Avatar, Recolor = Recolor, Engine = m.Engine,
        memory = memory, native = m.native, pool = pool, game = m.game, read = Avatar.reader(memory), note = note,
        remote = remote, records_same = records_same})
    local queues = {remote = remote, card = lineup} -- the targets whose requests and results their module keeps
    local cloak = new_cloak(m) -- Hide Cape: the capes hidden on this screen
    state.syncing = session ~= nil
    state.sync_text = session and m.Sync.encode(state.options) or nil
    -- Recolor Weapons: the local Helldiver's weapons, a target of their own (src/loadout.lua).
    local loadout = m.Weapons and m.Loadout and m.Loadout.new({Weapons = m.Weapons, Recolor = Recolor, Engine = m.Engine,
        Avatar = Avatar, memory = memory, native = m.native, pool = pool, game = m.game, read = Avatar.reader(memory),
        note = note})
    local self = {state = state, controller = controller, ui_controller = ui_controller, pool = pool, remote = remote,
                  session = session, loadout = loadout, lineup = lineup, cloak = cloak}

    -- Whether the weapons are recolored: Recolor Weapons on while something local is (not in the test build's loopback,
    -- where the sync path recolors the avatar).
    local function weapons_on()
        return loadout ~= nil and state.options.recolor_weapons and state.active and not state.loopback
    end

    local function maybe_yield()
        if time() >= state.budget_end then coroutine.yield() end
    end

    -- Recolor Squadmates: the settings squadmates take (src/remote.lua update's mine; a new table per change, which
    -- the squadmates' entries compare), or nil when it is off or this player's own recoloring is. With Squadmates'
    -- Colors on Your Colors and no paint scheme, the mode's source item of this player's kits: source_kit (the armor
    -- for Helmet Matches Armor, the helmet for Armor Matches Helmet) or source_cape (Helmet and Armor Match Cape).
    local function squad_settings()
        local o, id = state.options, state.identity
        if o.squad == Addon.SQUAD_OFF or (o.mode == Recolor.OFF and o.scheme == 0) then
            state.squad_mine = nil
            return
        end
        local mine = {mode = o.mode, keep_sets = o.keep_sets, recolor_hoods = o.recolor_hoods,
                      match_materials = o.match_materials, recolor_cape = o.recolor_cape,
                      recolor_weapons = o.recolor_weapons, scheme = o.scheme}
        if o.squad_colors == Addon.SQUAD_YOURS and o.scheme == 0 and id then
            mine.source_cape = o.mode == Recolor.CAPE_SOURCE and id.cape or nil
            mine.source_kit = o.mode == Recolor.ARMOR_FROM_HELMET and id.helmet
                or (o.mode == Recolor.HELMET_FROM_ARMOR and id.armor) or nil
        end
        state.squad_mine = mine
    end

    -- Hide Cape: the local Helldiver's capes (slot 1 of the unit watch's refs, no read) hidden while the choice hides
    -- them (on adopt and on a unit change: a respawn, another cape), shown again when it is off.
    local function cloak_local()
        if not cloak then return end
        if state.options.hide_cape == Addon.HIDE_OFF then return cloak.drop('local', true) end
        if state.watch then cloak.wear('local', state.watch.ref, false, state.frame) end
    end

    -- The local player's UI preview, located with the identity; kept while it is the same slot record (with the squad
    -- cards, the same preview system: src/lineup.lua names the player's slot).
    local function locate_ui(identity, frame)
        local where = Preview and Preview.locate(read, m.game, identity.ui_slot)
        local ui = state.ui
        if ui and where and (ui.where.record == where.record or (lineup and ui.where.system == where.system)) then
            return
        end
        if ui then ui_controller.restore(frame) end
        if ui and lineup then lineup.clear(frame) end
        state.ui = where and {where = where, watch = Preview.watch(memory, where), shown = false, dirty = false} or nil
    end

    local function adopt(identity, frame)
        identity = Avatar.copy(identity)
        state.identity, state.slot = identity, Avatar.preview_slot(memory, identity, read)
        squad_settings() -- Your Colors follows this player's kits
        state.watch = Avatar.watch(memory, identity, state.slot)
        state.watch.changed(true) -- keeps the current units and copies: later frames report only later changes
        state.next_verify, state.dirty, state.found_at = frame + Addon.VERIFY_FRAMES, true, frame
        cloak_local()
        locate_ui(identity, frame)
        if weapons_on() then -- another Helldiver (a new mission) or other kits: its weapons, planned for them
            loadout.adopt(identity)
            loadout.replan()
        end
        note(string.format('Local Helldiver: avatar %d, helmet %08x, armor %08x, body %d%s%s.', identity.avatar_index,
            identity.helmet, identity.armor, identity.body, state.slot and ', preview slot found' or '',
            state.ui and (', UI preview slot ' .. state.ui.where.slot) or ''))
    end

    -- A kept game-data reader (release_reader) closed: when the UI preview closes, the Helldiver is lost or no job came
    -- for KEEP_FRAMES frames; never under a running job (its finish keeps or closes it).
    -- Its files' handles are queued and closed CLOSES_PER_CHECK at a time on binding checks (check_bindings).
    local function close_kept()
        if not state.reader_kept or state.job then return end
        state.reader_kept = nil
        local reader = state.holder.pipeline
        if reader then
            reader.close()
            state.closing = true
        end
    end

    local function lose(frame, why)
        state.identity, state.watch, state.slot, state.found_at = nil, nil, nil, nil
        state.next_resolve = frame + Addon.RESOLVE_FRAMES
        controller.prune()
        if cloak then cloak.drop('local', false) end -- left hidden: no flash while the Helldiver is briefly not found
        if loadout then loadout.clear(frame) end
        if state.ui then
            ui_controller.restore(frame)
            if lineup then lineup.clear(frame) end
            state.ui = nil
        end
        close_kept()
        if why ~= state.why then
            state.why = why
            note('No local Helldiver (' .. tostring(why) .. ').')
        end
    end

    local plan_ahead -- what a resolve that found no Helldiver lets the next frame prepare (below)

    local function resolve(frame)
        state.next_resolve = frame + Addon.RESOLVE_FRAMES
        local identity, why, found = Avatar.resolve(memory, m.game, read, probe)
        if identity then
            state.why = nil
            adopt(identity, frame)
            return
        end
        if why ~= state.why then
            state.why = why
            note('Waiting for the local Helldiver (' .. tostring(why) .. ').')
        end
        plan_ahead(found)
    end

    -- Whether the worn (or previewed) cape matters to a request of mode, scheme and capes (Recolor Cape): Recolor Cape
    -- on, or Helmet and Armor Match Cape without a paint scheme (the cape is the source; a scheme overrides the mode).
    local function cape_counts(mode, scheme, capes)
        return capes or (mode == Recolor.CAPE_SOURCE and (scheme or 0) == 0)
    end

    local function request_key(r)
        return table.concat({r.mode, r.scheme, r.keep_sets and 1 or 0, r.keep_hoods and 1 or 0, r.materials and 1 or 0,
                             r.helmet, r.armor, r.body, cape_counts(r.mode, r.scheme, r.capes) and r.cape or 0}, ':')
    end

    -- The mode and paint scheme of a request for target: the options', except the avatar's (and its work ahead) in the
    -- test build's loopback (off: the sync path recolors it from the shared value, as it would another player).
    local function mode_of(target)
        if (target == 'avatar' or target == 'prepare') and state.loopback then return Recolor.OFF, 0 end
        return state.options.mode, state.options.scheme
    end

    -- cape_counts for the options' requests for target.
    local function options_cape_counts(target)
        local mode, scheme = mode_of(target)
        return cape_counts(mode, scheme, state.options.recolor_cape)
    end

    -- Whether the options changed since request r was made (its result no longer applies; a new job follows).
    local function options_changed(r)
        local o = state.options
        local mode, scheme = mode_of(r.target)
        return mode ~= r.mode or scheme ~= r.scheme or o.keep_sets ~= r.keep_sets
            or (not o.recolor_hoods) ~= r.keep_hoods or o.match_materials ~= r.materials or o.recolor_cape ~= r.capes
    end

    -- Whether kits differ from the ones request r was made for (the cape counts only when cape_counts).
    local function kits_changed(r, helmet, armor, body, cape)
        return helmet ~= r.helmet or armor ~= r.armor or body ~= r.body
            or (cape_counts(r.mode, r.scheme, r.capes) and cape ~= r.cape)
    end

    -- New units of the same Helldiver, kits and options (a respawn, a body copy): the applied result is bound to
    -- them at once, as its job would (no job, no resolve: verify has just resolved the identity). False when there
    -- is no such result (a job then).
    local function rebind(frame)
        local result, request, id = controller.result, state.applied, state.identity
        if not result or not request or state.dirty or options_changed(request)
            or kits_changed(request, id.helmet, id.armor, id.body, id.cape)
            or not records_same(result, id.helmet, id.armor,
                                cape_counts(request.mode, request.scheme, request.capes) and id.cape or nil) then
            return false
        end
        controller.apply(result, state.identity, state.slot, frame)
        return true
    end

    -- Resolves the local player again: a different Helldiver, kits or preview slot is adopted (a change);
    -- changed: the units already differ, so the same identity's result is bound to the new ones (a job when there is
    -- none) and dead units' bindings dropped. Another cape needs a job only when it counts (Recolor Cape on, or the cape
    -- as the source); it is kept current either way, so turning either on uses the cape worn then. With nothing local recolored (Color Matching
    -- off, no scheme) new units need nothing (v1.3 ran a job to restore nothing on every respawn).
    local function verify(frame, changed)
        state.next_verify = frame + Addon.VERIFY_FRAMES
        local identity, why = Avatar.resolve(memory, m.game, read, probe)
        if not identity then return lose(frame, why) end
        local slot = Avatar.preview_slot(memory, identity, read)
        local rebound = false -- an apply prunes dead units' bindings itself
        if not same_identity(identity, state.identity) or slot ~= state.slot then
            adopt(identity, frame)
        elseif state.active and options_cape_counts('avatar') and identity.cape ~= state.identity.cape then
            state.dirty = true
            if weapons_on() then loadout.replan() end -- the cape may be the weapons' source
        elseif changed and state.active then
            rebound = rebind(frame)
            state.dirty = state.dirty or not rebound
        end
        state.identity.cape = identity.cape
        if changed and not rebound and #controller.bindings > 0 then controller.prune() end
        if changed then cloak_local() end -- Hide Cape: new units (their refs from the watch, no read)
    end

    -- After applying: the cache status and the mods' patches once; new analyses are written later by the save job
    -- (save_step).
    local function note_cache(reader, frame)
        if reader.cache_status and not state.cache_logged then
            state.cache_logged = true
            note('Analysis cache: ' .. reader.cache_status .. '.')
        end
        if reader.patch_status and not state.patches_logged then
            state.patches_logged = true
            note('Mods: ' .. reader.patch_status .. '.')
        end
        if reader.dirty then state.save_at = frame + Addon.SAVE_DELAY_FRAMES end
    end

    -- Applies a result with `ctl`; the count, the apply's time in ms, how many textures had to be made and how many
    -- free ones were refilled.
    local function timed_apply(ctl, result, identity, slot, frame)
        local made, refilled, started = pool.made, pool.refilled, time()
        local count = ctl.apply(result, identity, slot, frame)
        return count, (time() - started) * 1000, pool.made - made, pool.refilled - refilled
    end

    -- The pool's decal sheet lines since the last ones logged (src/engine.lua took_sheet: made, or refilled over which
    -- sheet), so a garbled cape design in a report can be told apart from a recipe (v1.5).
    local function note_sheets()
        local notes = pool.sheet_notes
        for i = 1, #notes do
            note(notes[i] .. '.')
            notes[i] = nil
        end
    end

    -- A mod texture's line (src/albedo.lua: the colors read, how many recolored), once per plan; the Armory preview's
    -- too, so a modded hat only previewed still shows in the log that it was read (live 2026-10-14).
    local function note_albedo(result)
        if result.albedo_report and result.albedo_report ~= state.albedo_report then
            note(result.albedo_report)
            state.albedo_report = result.albedo_report
        end
    end

    -- A cape plan's development line (src/capes.lua Capes.report) and a mod texture's, once per plan.
    local function note_cape(result)
        if result.cape_report and result.cape_report ~= state.cape_report then
            note(result.cape_report)
            state.cape_report = result.cape_report
        end
        note_albedo(result)
    end

    -- The log lines of an applied result (applied: the apply's ms, the textures it made, its longest frame and, for
    -- the first result after the Helldiver was found, how many frames later it came).
    local function log_result(result, request, count, reader, applied)
        if result.action ~= 'apply' then
            if result.reason ~= state.last_reason then note('Original colors (' .. tostring(result.reason) .. ').') end
            return
        end
        local luts = 0
        for _ in pairs(result.luts) do luts = luts + 1 end
        local job = state.last_job
        local how = (request.scheme > 0 and ('paint scheme ' .. request.scheme) or Addon.MODE_NAMES[request.mode])
            .. (request.keep_hoods and ', hoods kept' or '') .. (request.materials and ', materials matched' or '')
            .. (request.capes and ', cape' or '')
        note(string.format('Recolored %d materials (%s, %d LUTs; job %.1f ms of work over %d frames, longest '
            .. 'slice %.1f ms in %s, heap %+.0f KB; applied in %.2f ms, %d new, %d refilled textures; longest frame '
            .. '%.1f ms%s).', count, how, luts, job.work * 1000, job.frames, job.longest * 1000,
            tostring(job.longest_stage), job.heap_kb, applied.ms, applied.made, applied.refilled,
            applied.frame * 1000, after_text(applied.after)))
        note_cape(result)
        note_sheets()
        if reader and reader.reads > 0 then
            note(string.format('Game data read so far: %d reads, %.1f MB, longest read %.1f ms (%d KB), %d frames '
                .. 'waited on the disk.', reader.reads, reader.bytes / 1048576, reader.longest * 1000,
                reader.longest_size / 1024, reader.waits or 0))
        end
    end

    local poll_ui -- the UI preview's per-frame check (below)

    -- A UI preview job's result, applied when the preview still shows its kits with the same options, read again
    -- now: the step does not watch the preview while a job runs, and v1.3 applied a pair the player had already left
    -- (the audit, rank 4). Else, or when the job ended early as obsolete, a new job follows for what is shown.
    local function finish_ui(result, request, frame, reader)
        local ui = state.ui
        if ui and ui.shown then poll_ui(frame) end
        if not ui or not ui.shown then return end
        if result.action == 'obsolete' or kits_changed(request, ui.helmet, ui.armor, ui.body, ui.cape)
            or options_changed(request) then
            ui.dirty = true
            return
        end
        local key = ui_controller.key
        local count, ms, made, refilled = timed_apply(ui_controller, result,
                                                      {units_at = ui.where.units_at, body = request.body}, nil, frame)
        ui.applied, ui.dirty = request, false -- what ui_controller.result was made for (poll_ui's rebind); current
        if reader then note_cache(reader, frame) end
        if result.action == 'apply' and (count > 0 or result.key ~= key) then
            local job = state.last_job
            note(string.format('Preview recolored: %d materials (helmet %08x, armor %08x%s; job %.1f ms of work over '
                .. '%d frames, longest slice %.1f ms; applied in %.2f ms, %d new, %d refilled textures; longest frame '
                .. '%.1f ms).', count, request.helmet, request.armor,
                cape_counts(request.mode, request.scheme, request.capes) and string.format(', cape %08x', request.cape or 0) or '', job.work * 1000,
                job.frames, job.longest * 1000, ms, made, refilled,
                math.max(job.longest, time() - state.frame_started) * 1000))
            note_albedo(result)
        end
        note_sheets()
    end

    -- The local player resolved again for a finished job: nil when the result no longer applies (the kits or
    -- the options changed while it ran; a new job follows).
    local function still_current(request, frame)
        local now, why = Avatar.resolve(memory, m.game, read, probe)
        if not now then return lose(frame, why) end
        if kits_changed(request, now.helmet, now.armor, now.body, now.cape) then
            return adopt(now, frame)
        end
        if options_changed(request) then
            state.dirty = true
            return nil
        end
        return now
    end

    -- A job done ahead of the Helldiver (plan_ahead): nothing to apply; its plan's textures are made now, while the
    -- game loads (pool.stock), not on the Helldiver's first frames. A failure is noted, not counted: the Helldiver's
    -- own job runs anyway and counts its own (a world still loading may lack what this one read).
    local function finish_ahead(ok, result, request, frame, reader)
        if not ok then
            note('Preparing ahead of the Helldiver failed: ' .. tostring(result))
            return
        end
        if reader then note_cache(reader, frame) end
        local job = state.last_job
        local made, ms = 0, 0
        if request.helmet and result.action == 'apply' then
            local started = time()
            made = pool.stock(result)
            ms = (time() - started) * 1000
        end
        note(string.format('Prepared ahead of the Helldiver: %s (%.1f ms of work over %d frames, longest slice %.1f ms '
            .. 'in %s; %d textures made ahead in %.2f ms).', request.helmet and string.format('plans of helmet %08x, '
            .. 'armor %08x', request.helmet, request.armor) or 'analysis cache and game data', job.work * 1000,
            job.frames, job.longest * 1000, tostring(job.longest_stage), made, ms))
    end

    -- The game-data reader after a job (the index, the archives' chunk tables and decoded chunks: at most about 10 MB):
    -- kept while the UI preview is shown, for the next item's job, else closed on the next binding check without a job
    -- (close_kept, within CHECK_FRAMES frames; a job before then takes it as it is). Each job opened it again (v1.3): a
    -- new item's job then read the index and the heads and chunk tables of 11-19 archives again, about 25 of a new
    -- armor's 62 frames waited on the disk (live 2026-10-08). Closing it took 0.35 ms with 3-4 archives open (about 0.09
    -- ms an archive; harness 2026-10-11, research/profiling/close_bench.py), and it was closed on the frame of the apply
    -- (v1.3, and v1.4 before its performance pass). A kept reader also closes at a pause or stop.
    local function release_reader(frame)
        if state.ui and state.ui.shown then
            state.reader_kept = frame
        else
            state.reader_kept = frame - Addon.KEEP_FRAMES -- due: the next binding check closes it
        end
    end

    -- A weapons job's result (src/loadout.lua): applied while the Helldiver, its kits and the options are the ones it
    -- was planned for and it holds the same weapons, else a new job follows.
    -- Whether a weapons result is no longer wanted (the option off, other options or kits, or obsolete); a wanted
    -- weapons plan is asked for again (preview: the Armory's preview weapon's).
    local function weapons_stale(request, result, preview, frame)
        local id = state.identity
        local stale = not id or options_changed(request) or kits_changed(request, id.helmet, id.armor, id.body, id.cape)
        if weapons_on() and not stale and result.action ~= 'obsolete' then return false end
        if weapons_on() and preview then loadout.preview_changed(frame) elseif weapons_on() then loadout.replan() end
        return true
    end

    local function finish_weapons(ok, result, request, frame, reader)
        if not ok then
            state.failures[request.key] = (state.failures[request.key] or 0) + 1
            note('Weapons recolor failed (' .. state.failures[request.key] .. '/' .. Addon.FAILURE_LIMIT .. '): '
                 .. tostring(result))
            return
        end
        if reader then note_cache(reader, frame) end
        local preview = request.target == 'ui_weapon'
        if weapons_stale(request, result, preview, frame) then return end
        local started, made = time(), pool.made
        local count = preview and loadout.finish_preview(result, request, frame) or loadout.finish(result, request, frame)
        if not count then return end -- the weapons changed while it ran: planned again
        local job = state.last_job
        if result.action == 'apply' then
            note(string.format('%s: %d materials (%d weapons, %d LUTs; job %.1f ms of work over %d frames, longest '
                .. 'slice %.1f ms; applied in %.2f ms, %d new textures).', preview and 'Weapon preview recolored'
                or 'Weapons recolored', count, #result.targets, Addon.count(result.luts), job.work * 1000, job.frames,
                job.longest * 1000, (time() - started) * 1000, pool.made - made))
        elseif result.reason ~= state.weapons_reason then
            note('Weapons keep their colors (' .. tostring(result.reason) .. ').')
        end
        state.weapons_reason = result.reason
    end

    -- A failed job of the local Helldiver: counted per request (Addon.FAILURE_LIMIT) and noted.
    local function job_failed(request, result)
        local key = request_key(request)
        state.failures[key] = (state.failures[key] or 0) + 1
        state.status = 'failed: ' .. tostring(result)
        note('Recolor failed (' .. state.failures[key] .. '/' .. Addon.FAILURE_LIMIT .. '): ' .. tostring(result))
    end

    -- Another mod user's Helldiver (or weapons), or a squad card (the preview polled first: a card that changed
    -- meanwhile wants a new job): its entry or card counts its own failures.
    local function finish_remote(ok, result, request, frame, reader)
        if request.target == 'card' and state.ui then poll_ui(frame) end
        queues[request.target].finish(ok, result, request, frame)
        note_sheets()
        if ok and reader then note_cache(reader, frame) end
    end

    -- The local Helldiver's plan, applied while its request is still current, and logged.
    local function finish_local(result, request, frame, reader)
        local now = still_current(request, frame)
        if not now then return end
        local count, ms, made, refilled = timed_apply(controller, result, now, Avatar.preview_slot(memory, now, read),
                                                      frame)
        state.applied = request -- what controller.result was made for (rebind)
        if reader then note_cache(reader, frame) end
        state.status = result.action == 'apply' and 'active' or ('vanilla: ' .. tostring(result.reason))
        local after = state.found_at and frame - state.found_at
        state.found_at = nil
        -- the job's longest frame of its own work: its longest slice, or this frame's slice, close, resolve and apply
        log_result(result, request, count, reader, {ms = ms, made = made, refilled = refilled, after = after,
                                                    frame = math.max(state.job_slice, time() - state.frame_started)})
        state.last_reason = result.reason
    end

    local function finish(ok, result, frame)
        local request = state.request
        state.job, state.request = nil, nil
        local reader = state.holder.pipeline
        if reader then release_reader(frame) end
        state.last_job = {seconds = time() - state.job_started, frames = frame - state.job_frame + 1,
                          work = state.job_work, longest = state.job_slice, longest_stage = state.job_slice_stage,
                          heap_kb = gcinfo() - state.job_heap}
        if queues[request.target] then return finish_remote(ok, result, request, frame, reader) end
        if request.weapons then return finish_weapons(ok, result, request, frame, reader) end
        if request.target == 'prepare' then return finish_ahead(ok, result, request, frame, reader) end
        if not ok then return job_failed(request, result) end
        if request.target == 'ui' then return finish_ui(result, request, frame, reader) end
        return finish_local(result, request, frame, reader)
    end

    -- One slice of the running job. A job whose last slice took more than APPLY_ALONE (all but one that did next to
    -- nothing, as Off's restore) is applied on the next frame: the apply has a frame to itself, a frame later. Before
    -- v1.4's performance pass a last slice under BUDGET / 2 was applied at once: in game a plan kept from before ends
    -- in a 0.3-0.7 ms slice and an outfit's apply takes 0.5-2.0 ms, and such frames took 2.0-2.8 ms (harness profile
    -- 2026-10-11, KB match-your-colors-stress-test).
    -- frame_started: where this frame's job work began (the log's longest frame; the audit, rank 10).
    local function run_job(frame)
        local started = time()
        state.frame_started = started
        if state.ended then
            local ok, result = state.ended_ok, state.ended_result
            state.ended, state.ended_result = false, nil
            return finish(ok, result, frame)
        end
        state.budget_end = started + Addon.BUDGET
        local ok, result = coroutine.resume(state.job)
        local slice = time() - started
        state.job_work = state.job_work + slice
        if slice > state.job_slice then state.job_slice, state.job_slice_stage = slice, state.holder.stage end
        if coroutine.status(state.job) ~= 'dead' then return end
        if slice > Addon.APPLY_ALONE then
            state.ended, state.ended_ok, state.ended_result = true, ok, result
            return
        end
        finish(ok, result, frame)
    end

    -- A request for target ('avatar', 'ui' or 'prepare') with the options, without kits.
    local function options_request(target)
        local o = state.options
        local mode, scheme = mode_of(target)
        return {target = target, mode = mode, scheme = scheme, keep_sets = o.keep_sets,
                keep_hoods = not o.recolor_hoods, materials = o.match_materials, capes = o.recolor_cape}
    end

    -- request with the kits of `from` (an identity, the UI preview's state or a resolve's probe).
    local function with_kits(request, from)
        request.helmet, request.armor, request.body, request.cape = from.helmet, from.armor, from.body, from.cape
        return request
    end

    -- The request for a target ('avatar', 'ui' or 'remote'), or nil (a preview not showing two kits yet, no other
    -- mod user's Helldiver waiting).
    local function request_for(target)
        if queues[target] then return queues[target].request() end
        if target == 'weapons' or target == 'ui_weapon' then
            local w = target == 'weapons' and loadout.request() or (target == 'ui_weapon' and loadout.preview_request())
            if not w or not state.identity then return nil end
            local request = with_kits(options_request(target), state.identity)
            request.weapons, request.sig = w.weapons, w.sig
            request.key = target .. ':' .. request_key(request) .. ':' .. w.sig
            return request
        end
        if target == 'ui' then
            local ui = state.ui
            ui.dirty = false
            if not ui.helmet or ui.helmet == 0 or ui.armor == 0 then return nil end
            return with_kits(options_request(target), ui)
        end
        state.dirty = false
        return with_kits(options_request(target), state.identity)
    end

    -- Work ahead of the Helldiver. The first recolor came 7-13 frames of job after the Helldiver was found (half a
    -- second in play with the resolve's cadence, user report 2026-10-08): the pipeline's construction (analysis cache,
    -- game data index) and the plans. A resolve that found a world loading (a player manager) asks for the pipeline,
    -- once; one that found the local player's real kits before the Helldiver asks for their analyses and plans, once
    -- per request. The next frame starts that job (start_ahead); the Helldiver's own job then finds them made (live:
    -- applied 1 frame after the Helldiver was found, 13 before). The work is the first job's, moved to loading frames
    -- at BUDGET a frame, not added: nothing while nothing local is recolored, nothing for stand-in kits, for kits
    -- already applied (a respawn) or already prepared.
    plan_ahead = function(found)
        if not state.active or found == Avatar.FOUND_NOTHING then return end
        if found == Avatar.FOUND_KITS and real_kits(probe, options_cape_counts('prepare')) then
            local request = with_kits(options_request('prepare'), probe)
            local key = request_key(request)
            if key == state.prepared or (state.applied and request_key(state.applied) == key) then return end
            state.prepared, state.warm = key, request
        elseif not (state.holder.pipeline or state.pipeline_asked) then
            state.pipeline_asked, state.warm = true, options_request('prepare')
        end
    end

    -- start_job(frame, target[, request]): request given for work ahead (plan_ahead's), else made for target.
    local function start_job(frame, target, request)
        request = request or request_for(target)
        if not request then return end
        local own = not queues[target]
        local key = own and (request.weapons and request.key or (request.helmet and request_key(request)))
        if key and (state.failures[key] or 0) >= Addon.FAILURE_LIMIT then return end
        state.request = request
        state.job_started, state.job_frame, state.job_work, state.job_slice = time(), frame, 0, 0
        state.job_heap = gcinfo() -- the Lua heap in KB (read only)
        local job = request.weapons and Recolor.weapons_job or Recolor.job
        state.job = coroutine.create(function()
            return job(job_deps, state.holder, request, maybe_yield)
        end)
        run_job(frame)
    end

    -- The disk cache's save job, due SAVE_DELAY_FRAMES frames after a recolor job made new analyses: it waits while
    -- the UI preview is shown (browsing the Armory makes many), runs only on frames without a recolor job, with
    -- BUDGET of work per frame, and pauses between entries (v1.1 wrote the whole file on the frame of a recolor).
    local function save_step(frame)
        local reader = state.holder.pipeline
        if not reader then
            state.save_at = nil
            return
        end
        if state.ui and state.ui.shown then
            state.save_at = frame + Addon.SAVE_DELAY_FRAMES
            return
        end
        if not state.saving then
            state.saving = coroutine.create(function() return reader.save(maybe_yield) end)
            state.save_work, state.save_frames, state.save_slice = 0, 0, 0
        end
        local started = time()
        state.budget_end = started + Addon.BUDGET
        local ok, saved, why = coroutine.resume(state.saving)
        local slice = time() - started
        state.save_work, state.save_frames = state.save_work + slice, state.save_frames + 1
        if slice > state.save_slice then state.save_slice = slice end
        if coroutine.status(state.saving) ~= 'dead' then return end
        state.saving = nil
        state.save_at = reader.dirty and frame + Addon.SAVE_DELAY_FRAMES or nil
        if ok and saved then
            note(string.format('Analysis cache saved (%.1f ms of work over %d frames, longest slice %.1f ms).',
                state.save_work * 1000, state.save_frames, state.save_slice * 1000))
        else
            note('Analysis cache not saved: ' .. tostring(ok and why or saved))
        end
    end

    -- Every CHECK_FRAMES frames: one recolored material per runtime texture still holds its texture.
    local function check_bindings(frame)
        state.next_check = frame + Addon.CHECK_FRAMES
        if controller.probes > 0 and not controller.check() then
            state.dirty = true
            note('The game put an original color texture back on a recolored material; applying again.')
        end
        if state.ui and ui_controller.probes > 0 and not ui_controller.check() then state.ui.dirty = true end
        if lineup and next(lineup.cards) then lineup.check() end
        if weapons_on() then loadout.check(frame) end
        if cloak and cloak.order[1] then cloak.check(frame) end -- Hide Cape: one hidden cape still hidden (1 read)
        if state.reader_kept and frame - state.reader_kept >= Addon.KEEP_FRAMES then close_kept() end
        if state.closing and m.Files then state.closing = m.Files.close_some(Addon.CLOSES_PER_CHECK) > 0 end
    end

    -- The UI preview's check: a second check this frame, of other memory than the avatar's (the preview's own
    -- units and kits); on 1 frame in UI_GATE_FRAMES while it is not shown, every frame while it is.
    -- The preview hidden: its plan's bindings put back (shown again: a job for its new units).
    local function ui_hidden(ui, frame)
        if not ui.shown then return end
        ui.shown, ui.dirty = false, false
        ui.helmet, ui.armor, ui.body, ui.cape = nil, nil, nil, nil
        ui_controller.restore(frame)
        close_kept()
    end

    -- Other kits shown: a new job only for kits that matter (a cape shown counts only when cape_counts).
    local function ui_kits(ui)
        local helmet, armor, body, cape = ui.watch.kits()
        if helmet ~= ui.helmet or armor ~= ui.armor or body ~= ui.body
            or (options_cape_counts('ui') and cape ~= ui.cape) then
            ui.dirty = true
        end
        ui.helmet, ui.armor, ui.body, ui.cape = helmet, armor, body, cape
    end

    -- New units shown: the same plan binds them at once when it is applied for these kits and options, else a job.
    local function ui_units(ui, frame)
        local r = ui.applied
        if ui.dirty or not ui_controller.result or not r or options_changed(r)
            or kits_changed(r, ui.helmet, ui.armor, ui.body, ui.cape)
            or not records_same(ui_controller.result, ui.helmet, ui.armor,
                                cape_counts(r.mode, r.scheme, r.capes) and ui.cape or nil) then
            ui.dirty = true
        else
            ui_controller.apply(ui_controller.result, {units_at = ui.where.units_at, body = r.body}, nil, frame)
        end
    end

    -- The squad cards when a slot changed or after a lobby poll (src/lineup.lua), then the preview's status as the
    -- player's own: moved to the shown slot that is the player's (the slot it leaves given back first; nil: nothing more
    -- this poll), 'absent' when none is, 'kits' for a slot given back to it (a card before: live 2026-10-15).
    local function own_status(ui, status, frame)
        if ui.watch.changes > 0 or lineup.stale or lineup.remap then
            lineup.own = lineup.observe(frame, ui.watch, state.identity, state.loopback)
        end
        local own = lineup.own
        if own and own ~= ui.where.slot then
            ui_hidden(ui, frame)
            Preview.retarget(ui.where, own)
            return ui.watch.reset()
        end
        if not own then return 'absent' end
        return (not ui.shown and status ~= 'absent') and 'kits' or status
    end

    poll_ui = function(frame)
        local ui = state.ui
        local status = ui.watch.poll()
        -- the Armory's weapon preview: its ring head, in the same read (src/preview.lua ring_moved)
        if loadout and ui.watch.ring_moved() and weapons_on() then loadout.preview_changed(frame) end
        if lineup then status = own_status(ui, status, frame) end
        if not status then return end
        if status == 'absent' then return ui_hidden(ui, frame) end
        ui.shown = true
        if status == 'kits' then
            ui_kits(ui)
        elseif status == 'units' then
            ui_units(ui, frame)
        end
    end

    -- The UI preview's check when due (not while nothing local is recolored: it would show its own colors anyway),
    -- then a job when one is needed (the avatar's first).
    local function preview_and_jobs(frame)
        local ui = state.ui
        if ui and state.active and (ui.shown or frame % Addon.UI_GATE_FRAMES == 0) then poll_ui(frame) end
        if state.dirty and state.identity then
            start_job(frame, 'avatar')
        elseif state.ui and state.ui.dirty then
            start_job(frame, 'ui')
        elseif lineup and lineup.pending then
            start_job(frame, 'card')
        elseif loadout and loadout.dirty and weapons_on() then
            start_job(frame, 'weapons')
        elseif loadout and loadout.preview_dirty and weapons_on() then
            start_job(frame, 'ui_weapon')
        end
    end

    -- The lobby poll: this player's value posted when due, the members' values to the other players' recolors (with
    -- Recolor Squadmates, this player's settings for those who share none, or for everyone).
    local function poll_sync(frame)
        state.next_sync = frame + m.Sync.POLL_FRAMES
        local members = session.poll(frame, state.sync_text, state.loopback)
        remote.update(frame, members, state.squad_mine, state.options.squad == Addon.SQUAD_EVERYONE)
        if lineup then lineup.stale = true end -- the cards look at their players' settings again
        -- Hide Cape: the next frame, when a cape is to be hidden or other players' are (no read to tell)
        if cloak and cloak.needed(members, state.options.hide_cape == Addon.HIDE_EVERYONE) then
            state.cloak_members, state.cloak_due = members, true
        end
    end

    -- Hide Cape: the other players whose capes are hidden here, on the frame after a lobby poll (its own frame: the
    -- players are read then) or after the choice changed; members: the poll's (reused until the next poll).
    local function cloak_update()
        state.cloak_due = false
        cloak.update(state.cloak_members, state.options.hide_cape == Addon.HIDE_EVERYONE, state.frame)
    end

    -- Sync With Mod Users, on a frame with no recolor job and no cache save: a second check this frame, of other
    -- memory than the local player's, because the squad's lobby and the other players' Helldivers change on their
    -- own. The lobby poll every Sync.POLL_FRAMES frames; while another player's Helldiver is recolored (or its
    -- textures retire), one unit watch on 1 frame in Remote.WATCH_FRAMES, else one binding check every CHECK_FRAMES
    -- frames and a job when one is due. Each frame does one of them at most; the calls into interpreted code are
    -- behind these compares.
    -- Hide Cape's watch of other players' capes takes the frames WATCH_FRAMES leaves the squad's (frame % 4 == 2, never
    -- a check frame: CHECK_FRAMES * k + 1 is odd).
    local WATCH_FRAMES = m.Remote and m.Remote.WATCH_FRAMES
    local function sync_step(frame)
        if frame >= state.next_sync and state.verified_at ~= frame then return poll_sync(frame) end
        if state.cloak_due then return cloak_update() end
        if cloak and cloak.others[1] and frame % WATCH_FRAMES == 2 then return cloak.step(frame) end
        if remote.order[1] == nil and remote.retiring[1] == nil then return end
        if frame % WATCH_FRAMES == 0 then return remote.step(frame) end
        if frame % Addon.CHECK_FRAMES == 1 then return remote.check() end
        if remote.pending then start_job(frame, 'remote') end
    end

    -- The job plan_ahead asked for, on the frame after its resolve (one heavy piece per frame).
    local function start_ahead(frame)
        local request = state.warm
        state.warm = nil
        start_job(frame, 'prepare', request)
    end

    -- The local Helldiver's checks and jobs: true when this frame resolved it, ran a recolor job or saved the cache
    -- (then nothing else runs this frame).
    local function local_step(frame)
        if not state.identity then
            if state.warm then -- work ahead first; a resolve due now waits for the frame after the job
                start_ahead(frame)
                return true
            end
            if frame < state.next_resolve then return false end
            resolve(frame)
            return true
        end
        -- the body-copy slot on odd frames (UI gate: frame % 4 == 0), only while something local is recolored
        local changed = state.watch.changed(state.active and frame % 2 == 1)
        -- One heavy periodic piece per frame: a chain check (about 20 reads) moves the binding check to the next
        -- frame, and the cache save slice and the lobby poll wait a frame too (sync_step: verified_at).
        local verified = changed or frame >= state.next_verify
        if verified then
            verify(frame, changed)
            state.verified_at = frame
        elseif frame >= state.next_check then
            check_bindings(frame)
        end
        -- Recolor Weapons: a second check this frame, of other memory than the avatar's (the weapon in hand's binding,
        -- which the game's reload binds again; the inventory row on 1 frame in 4); a resolve waits for a frame without
        -- a chain check (src/loadout.lua)
        if state.identity and weapons_on() then loadout.step(frame, verified) end
        preview_and_jobs(frame)
        if state.job_frame == frame then return true end -- a recolor job started (and maybe ended) this frame
        -- A second piece of work this frame only when the cache save is due and neither a recolor job nor a chain
        -- check ran this frame.
        if verified or not (state.save_at and frame >= state.save_at) then return false end
        save_step(frame)
        return true
    end

    -- While a UI preview job runs: the preview read on 1 frame in UI_GATE_FRAMES (poll_ui, one read, as on idle
    -- frames while it is shown). A second check on such frames, because the player keeps hovering items while a job
    -- for a new item runs for dozens of frames: when the preview shows other kits or closed, the request is obsolete and
    -- the job ends at its next stage boundary (Recolor.job) instead of planning, fitting and applying a pair nobody sees.
    local function watch_ui_job(frame, request)
        local ui = state.ui
        if ui then poll_ui(frame) end
        if not (ui and ui.shown) or kits_changed(request, ui.helmet, ui.armor, ui.body, ui.cape)
            or options_changed(request) then
            request.obsolete = true
        end
    end

    -- A controller's units that had no materials at its last apply (not ready yet) bound once they have them
    -- (Recolor controller settle). A second piece of work on a frame, only while such units are pending (a few frames
    -- after an apply); what: 'Helldiver' or 'Preview' for the log.
    local function settle(c, frame, what)
        local ok, count, outcome = pcall(c.settle, frame)
        if not ok then
            note(what .. ': binding units that were not ready failed: ' .. tostring(count))
            return
        end
        if count > 0 then
            note(string.format('%s: %d textures bound late (their materials were not ready at the apply).', what,
                               count))
        end
        if outcome == 'expired' and not state.expired_noted then
            state.expired_noted = true
            note(what .. ': a unit of the plan still had no materials 2 s after the apply; it keeps its own colors.')
        end
    end

    -- A frame with a recolor job: while it is the UI preview's, the preview read on 1 frame in UI_GATE_FRAMES
    -- (watch_ui_job); then the job's work.
    local function job_step(frame)
        local request = state.request
        if frame % Addon.UI_GATE_FRAMES == 0 and not state.ended and request and request.target == 'ui'
            and not request.obsolete then
            watch_ui_job(frame, request)
        end
        return run_job(frame)
    end

    -- Every frame, before the game's update.
    function self.step()
        local frame = state.frame + 1
        state.frame = frame
        if controller.retired[1] then controller.collect(frame) end
        if ui_controller.retired[1] then ui_controller.collect(frame) end
        if loadout and loadout.controller.retired[1] then loadout.collect(frame) end
        if controller.pending then settle(controller, frame, 'Helldiver') end
        if ui_controller.pending then settle(ui_controller, frame, 'Preview') end
        if lineup and lineup.busy then lineup.step(frame, settle) end
        -- Hide Cape: while this player's new cape is young, its helmet's mask read every frame (a second check on
        -- those frames: the hellpod's exit shows the cape again, src/cloak.lua); one compare otherwise
        if cloak and frame <= cloak.young_until then cloak.young(frame) end
        if state.job then return job_step(frame) end
        -- The lobby only while the local Helldiver exists (not on the title screen, while loading or dead): the lobby
        -- is settled then (its first post crashed the game on arrival on the ship, 2026-10-07: src/sync.lua).
        if local_step(frame) or not state.syncing or not state.identity then return end
        sync_step(frame)
    end

    -- Recolor Weapons after an option changed: the weapons found and planned when they are to be recolored (a job of
    -- their own), else their own colors back. Recolor Hoods changes no weapon.
    local function weapons_option(name)
        if not loadout then return end
        if not weapons_on() then
            loadout.clear(state.frame)
        elseif state.identity and name ~= 'recolor_hoods' then
            if not loadout.watch then loadout.adopt(state.identity) end
            loadout.replan()
            -- a weapon preview already shown (turned on in the Armory): read it now, not at its next change
            if not loadout.preview then loadout.preview_changed(state.frame) end
        end
    end

    -- An option from Mod Options Menu (or its default): mode (1-4), scheme (0 none, 1 to the schemes' count) or one
    -- of the toggles.
    local TOGGLES = {keep_sets = true, recolor_hoods = true, match_materials = true, recolor_cape = true,
                     recolor_weapons = true}
    local SCHEMES = m.Schemes and #m.Schemes.LIST or 0
    local function valid(name, value)
        if name == 'mode' then return value == 1 or value == 2 or value == 3 or value == 4 end
        if name == 'squad' or name == 'hide_cape' then return value == 1 or value == 2 or value == 3 end
        if name == 'squad_colors' then return value == 1 or value == 2 end
        if name == 'scheme' then
            return type(value) == 'number' and value % 1 == 0 and value >= 0 and value <= SCHEMES
        end
        return TOGGLES[name] == true and type(value) == 'boolean'
    end
    -- A value equal to the current one changes nothing (v1.3 ran a job for it: the audit, rank 13). Turning local
    -- recoloring back on (state.active) makes the preview, unwatched meanwhile, count as newly shown. Recolor
    -- Squadmates and, while it is on, every option reach the squadmates at the next frame's poll; it starts no job of
    -- this player's own.
    -- Hide Cape changed: the shared flag (squadmates hide this player's cape), this player's cape now, the other
    -- players' at the next frame (from the last poll's members); no recolor job.
    local function hide_option()
        local o = state.options
        o.cape_hidden = o.hide_cape ~= Addon.HIDE_OFF
        if session then state.sync_text = m.Sync.encode(o) end -- posted once it has settled (src/sync.lua)
        if state.identity then cloak_local() end
        state.cloak_due = cloak ~= nil and session ~= nil
    end

    function self.set_option(name, value)
        if not valid(name, value) then return end
        local o = state.options
        if o[name] == value then return end
        o[name] = value
        note('Option ' .. name .. ' = ' .. tostring(value) .. '.')
        if name == 'hide_cape' then return hide_option() end
        squad_settings()
        if name == 'squad' or o.squad ~= Addon.SQUAD_OFF then state.next_sync = state.frame + 1 end
        if name == 'squad' or name == 'squad_colors' then return end
        if session then state.sync_text = m.Sync.encode(o) end -- posted once it has settled (src/sync.lua)
        local was_active = state.active
        state.active = o.mode ~= Recolor.OFF or o.scheme ~= 0
        weapons_option(name)
        if name == 'recolor_weapons' then return end -- the weapons' own target alone (src/loadout.lua)
        state.dirty = true
        local ui = state.ui
        if not ui then return end
        if state.active and not was_active then
            ui.watch.reset()
            ui.shown, ui.dirty, ui.helmet, ui.armor, ui.body, ui.cape = false, false, nil, nil, nil, nil
        elseif ui.shown then
            ui.dirty = true
        end
    end

    -- The options in one line (logged once registered).
    function self.options_text()
        local o = state.options
        return string.format('mode %d, paint scheme %d, keep sets %s, recolor hoods %s, match materials %s, recolor '
            .. 'cape %s, recolor weapons %s, recolor squadmates %d, squadmates colors %d, hide cape %d', o.mode,
            o.scheme, tostring(o.keep_sets), tostring(o.recolor_hoods), tostring(o.match_materials),
            tostring(o.recolor_cape), tostring(o.recolor_weapons), o.squad, o.squad_colors, o.hide_cape)
    end

    -- Test builds only (reached through their global): the local player's own shared value drives the sync path
    -- on its own Helldiver, which the local recolor then leaves alone (one game cannot hold a second player).
    function self.set_loopback(on)
        state.loopback, state.dirty, state.next_sync = on == true, true, state.frame + 1
        if not session then return end
        -- Off: the sync path gives the Helldiver back at once, before the local recolor binds it again.
        if not state.loopback then remote.clear(state.frame) end
        note('Loopback ' .. (state.loopback and 'on' or 'off') .. '.')
    end

    -- The guard's pause (an update below this addon failed): original colors back, job dropped; a resume
    -- starts again from a fresh resolve.
    -- What a job or save dropped at a pause or stop left open: a read in flight (waited out), the handles of a reader
    -- it was building, the cache file between two pieces.
    local function release_files()
        if m.Files then m.Files.abandon() end
        if m.Cache then m.Cache.abort() end
    end

    function self.pause(reason)
        state.job, state.request, state.ended, state.ended_result = nil, nil, false, nil
        if state.saving then -- an unfinished save starts over later
            state.saving = nil
            if state.holder.pipeline then state.holder.pipeline.dirty = true end
        end
        if state.holder.pipeline then state.holder.pipeline.close() end
        state.reader_kept = nil
        release_files()
        controller.restore(state.frame)
        ui_controller.restore(state.frame)
        if loadout then loadout.clear(state.frame) end
        if lineup then lineup.clear(state.frame) end
        if remote then -- the next lobby poll after a resume finds the other players again
            remote.clear(state.frame)
            state.next_sync = 0
        end
        if cloak then cloak.clear() end -- capes shown, as without the mod; hidden again after a resume
        state.identity, state.watch, state.slot, state.ui, state.next_resolve = nil, nil, nil, nil, 0
        state.warm, state.found_at = nil, nil
        state.status = 'paused: ' .. tostring(reason)
        note('Paused (' .. tostring(reason) .. '); original colors until the addon resumes.')
    end

    -- At shutdown: a cache save still due (or under way) is written at once; the game is closing. A save under way
    -- has its temporary file open: it is closed and removed first (its handle would block the rename).
    local function save_at_shutdown()
        local reader = state.holder.pipeline
        if not (reader and (state.saving or state.save_at)) then return end
        if state.saving then
            reader.dirty = true
            if m.Cache then pcall(m.Cache.abort) end
        end
        local ok, saved, why = pcall(reader.save)
        note(ok and saved and 'Analysis cache saved at shutdown.'
             or ('Analysis cache not saved: ' .. tostring(ok and why or saved)))
    end

    -- The guard's stop: original colors back, except at shutdown (the game is closing).
    -- The shutdown line: the session's counts.
    local function note_shutdown()
        note('Shutdown: ' .. state.status .. string.format(' (applied %d, restored %d; textures made %d, '
            .. 'refilled %d, destroyed %d; cape sheets made %d, refilled %d', controller.applied,
            controller.restored, pool.made, pool.refilled, pool.destroyed, pool.sheets.made, pool.sheets.refilled)
            .. (session and string.format('; sync: %d posts, %d failed, other players recolored '
            .. '%d times', session.posts, session.failures, remote.jobs) or '')
            .. (loadout and loadout.jobs > 0 and string.format('; weapons: %d jobs, bound again %d times (%d '
            .. 'reloads)', loadout.jobs, loadout.rebinds, loadout.reloads) or '')
            .. (cloak and cloak.hidden > 0 and string.format('; capes hidden %d times, hidden again %d, shown %d',
            cloak.hidden, cloak.reshown, cloak.shown) or '') .. ').')
    end

    -- Every recolor put back (the local Helldiver's, the preview's, the other players', the weapons'): true, or false
    -- and the last problem.
    local function restore_all()
        local ok, problem = pcall(controller.restore, state.frame)
        local ui_ok, ui_problem = pcall(ui_controller.restore, state.frame)
        if ok and not ui_ok then ok, problem = false, ui_problem end
        for _, clear in ipairs({remote and remote.clear or false, loadout and loadout.clear or false,
                                lineup and lineup.clear or false, cloak and cloak.clear or false}) do
            local cleared, why = true, nil
            if clear then cleared, why = pcall(clear, state.frame) end
            if not cleared then ok, problem = false, why end
        end
        return ok, problem
    end

    function self.stopped(reason)
        if reason == 'shutdown' then
            save_at_shutdown()
            return note_shutdown()
        end
        state.job, state.ended, state.ended_result = nil, false, nil
        if state.holder.pipeline then pcall(state.holder.pipeline.close) end
        state.reader_kept = nil
        pcall(release_files)
        local ok, problem = restore_all()
        note('Stopped (' .. tostring(reason) .. ')' .. (ok and '' or ('; ' .. tostring(problem))))
    end

    -- Everything but the frame step (with the UI preview's and sync's per-frame gates), the idle check and the
    -- job's yield runs on few frames: interpreted.
    if type(jit) == 'table' and type(jit.off) == 'function' then
        for _, fn in ipairs({locate_ui, adopt, close_kept, lose, resolve, record_same, records_same, rebind, verify,
                             request_key,
                             mode_of, options_changed, kits_changed,
                             note_cache, timed_apply, note_sheets, note_albedo, note_cape, log_result, finish_ui,
                             still_current, finish_ahead,
                             release_reader, job_failed, finish_remote, finish_local, finish, run_job,
                             options_request, with_kits, request_for, plan_ahead, start_job, start_ahead, save_step,
                             check_bindings, poll_sync, valid, watch_ui_job, squad_settings, settle, weapons_on,
                             cloak_local, cloak_update, hide_option, job_step,
                             weapons_stale, finish_weapons, weapons_option,
                             self.set_option, self.options_text, self.set_loopback, release_files, self.pause,
                             save_at_shutdown, note_shutdown, restore_all, self.stopped}) do
            jit.off(fn, true)
        end
    end
    return self
end

-- The toggles in menu order: {option id, instance option name, label text, description text, default}.
Addon.TOGGLES = {
    {Addon.OPTION_SETS, 'keep_sets', 'option.sets.label', 'option.sets.description', true},
    {Addon.OPTION_HOODS, 'recolor_hoods', 'option.hoods.label', 'option.hoods.description', true},
    {Addon.OPTION_MATERIALS, 'match_materials', 'option.materials.label', 'option.materials.description', false},
    {Addon.OPTION_CAPES, 'recolor_cape', 'option.capes.label', 'option.capes.description', false},
    {Addon.OPTION_WEAPONS, 'recolor_weapons', 'option.weapons.label', 'option.weapons.description', false},
}

-- How many entries a table holds (a result's LUTs, for the log).
function Addon.count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Bingus Shared Loader v18+ with API 1, recognized by what it offers, never by its internal version.
function Addon.loader_ok(loader)
    return type(loader) == 'table' and loader.api == 1 and type(loader.open_log) == 'function'
end

-- Startup: checks, the instance, the guard and the options. m: {runtime, memory (bingus_memory module), T,
-- locales, Avatar, Preview, Recolor, Engine, Files, Slim, Patches, Texture, Colour, Transfer, Matcher, Kits, Schemes,
-- Sync, Remote, env}. Returns the instance, or nil when disabled.
function Addon.install(m)
    local loader = rawget(_G, 'CowboyBingusModLoader')
    local log_file
    if Addon.loader_ok(loader) then pcall(function() log_file = loader.open_log('MatchYourColors.log') end) end
    local function note(line)
        if log_file then pcall(function() log_file:write(line .. '\n'); log_file:flush() end) end
    end
    local function require_that(condition, reason) if not condition then error(reason, 0) end end
    local ready, instance = pcall(function()
        require_that(Addon.loader_ok(loader), 'Bingus Shared Loader v18+ / API 1 required')
        require_that(ffi.abi('64bit'), 'Windows x64 required')
        local memory = m.memory.new(m.runtime)
        local game, exe = memory.module('game.dll'), memory.module(nil)
        require_that(game ~= nil and exe ~= nil, 'game modules unavailable')
        local ok, why = memory.verify_build({exe_sha256 = Addon.EXE_SHA256, game_sha256 = Addon.GAME_SHA256})
        require_that(ok, why == 'unsupported game build' and 'unsupported game build (needs Steam build 25480438)'
                     or tostring(why))
        local native, problem = m.Engine.open(memory, memory.address(game), memory.address(exe), m.get_engine_api)
        require_that(native, tostring(problem))
        m.Matcher.use(m.Colour)
        m.Zones.attach(m.Matcher, m.Colour) -- a cape's design zones and emblems (src/zones.lua)
        m.Sheets.attach(m.Recolor) -- the emblem-sheet copies (src/sheets.lua)
        m.Bindings.attach(m.Recolor) -- the bindings controller (src/bindings.lua)
        m.Variety.attach(m.Matcher, m.Colour) -- an armor never left in one color (src/variety.lua)
        return Addon.new({Avatar = m.Avatar, Preview = m.Preview, Recolor = m.Recolor, Engine = m.Engine,
                          Files = m.Files, Slim = m.Slim,
                          Texture = m.Texture, Colour = m.Colour, Transfer = m.Transfer, Matcher = m.Matcher,
                          Kits = m.Kits, Schemes = m.Schemes, Capes = m.Capes, Patches = m.Patches, Sync = m.Sync,
                          Remote = m.Remote, Albedo = m.Albedo, Weapons = m.Weapons, Loadout = m.Loadout,
                          WeaponData = m.WeaponData, Lineup = m.Lineup, Cloak = m.Cloak,
                          memory = memory,
                          Appearance = m.Appearance and m.AppearanceData and m.Appearance.new(m.AppearanceData),
                          native = native, game = memory.address(game), note = note, Cache = m.Cache,
                          cache_path = m.Cache and m.Cache.path(loader)})
    end)
    if not ready then
        note('Disabled: ' .. tostring(instance))
        return nil
    end
    if m.Options then m.Options.attach(Addon) end -- Addon.options (src/options.lua)
    local tr = m.T.new(m.locales.en, m.locales.bundled, function(message) note('text: ' .. message) end)
    local options = Addon.options(instance, tr, note, m.Schemes)
    local step = instance.step
    local env = m.env or _G
    local guard = m.runtime.guard({name = 'MatchYourColors', log = note, env = env, pause = instance.pause,
        stop = instance.stopped, step = function()
            if options.due(instance.state.frame + 1) then options.attempt() end
            step()
        end}).install()
    instance.guard, instance.options = guard, options
    if type(loader.after_startup) == 'function' and type(loader.capabilities) == 'table'
        and loader.capabilities.after_startup == true then
        pcall(loader.after_startup, function() options.attempt() end)
    end
    rawset(env, 'MatchYourColorsInstalled', true) -- lint-ok: R8 the re-entry guard the generated entry checks
    note('Match Your Colors ' .. Addon.REVISION .. ' initialized (loader API ' .. tostring(loader.api) .. ').')
    return instance
end

-- Startup and option registration run once: interpreted, sub-functions included.
if type(jit) == 'table' and type(jit.off) == 'function' then
    for _, fn in ipairs({same_identity, real_kits, after_text, new_cloak, Addon.loader_ok,
                         Addon.install, Addon.count}) do
        jit.off(fn, true)
    end
end

return Addon
