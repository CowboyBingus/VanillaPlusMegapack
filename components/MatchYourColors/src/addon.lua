-- Match Your Colors: startup checks, the per-frame step, Mod Options Menu settings and the log.
--
-- Every frame, before the game's update (Bingus Shared Runtime's guard):
--   * no local Helldiver yet (title screen, loading, dead): one resolve every RESOLVE_FRAMES frames;
--   * idle: one read of the Helldiver's 120 unit bytes, plus one of its preview slot's entry count (and
--     entries while there are any); nothing else unless they changed;
--   * the UI preview of the local player (the Armory CHARACTER view, src/preview.lua): one 8-byte read on 1
--     frame in UI_GATE_FRAMES while it is not shown, that read and one of its 160-byte record every frame while
--     it is; a change of the kits it shows starts a job for that pair (its own textures and bindings);
--   * every VERIFY_FRAMES frames the whole local-player chain is resolved again;
--   * every CHECK_FRAMES frames one recolored material per runtime texture is read (two reads each): if the
--     game put its original LUT back, the recolor is applied again;
--   * a change (re-equip, respawn, a preview, an option) starts a job; a running job gets BUDGET seconds of
--     work per frame and its result is applied in one frame, refilling pooled textures (src/recolor.lua; making
--     a texture waits for the render thread, so new ones are made only when the pool has none of the size);
--   * new analyses go to the disk cache in a save job of its own (BUDGET per frame) once no recolor job runs and
--     the UI preview has been closed for SAVE_DELAY_FRAMES frames, at shutdown at the latest;
--   * Sync With Mod Users (src/sync.lua, src/remote.lua; always on, no option since 2026-10-07): every
--     Sync.POLL_FRAMES frames the squad's PlayFab lobby is read (and this player's settings posted when due); while
--     other mod users' Helldivers are recolored, one of them has its units checked per frame (round robin) and one
--     its bindings every CHECK_FRAMES frames.
-- No memory writes: the recolor goes through engine calls (src/engine.lua).
local ffi = require('ffi')

local Addon = {VERSION = '1.3'}
Addon.REVISION = 'v' .. Addon.VERSION
Addon.MOD_ID = 'cowboybingus.match_your_colors'
Addon.OPTION_MODE = 'cowboybingus.match_your_colors.mode'
Addon.OPTION_SCHEME = 'cowboybingus.match_your_colors.paint_scheme'
Addon.OPTION_SETS = 'cowboybingus.match_your_colors.keep_sets'
Addon.OPTION_HOODS = 'cowboybingus.match_your_colors.recolor_hoods'
Addon.OPTION_MATERIALS = 'cowboybingus.match_your_colors.match_materials'
Addon.OPTION_CAPES = 'cowboybingus.match_your_colors.recolor_cape'
Addon.RESOLVE_FRAMES = 15
Addon.VERIFY_FRAMES = 120
Addon.CHECK_FRAMES = 30
Addon.UI_GATE_FRAMES = 4
Addon.BUDGET = 0.0015
Addon.SAVE_DELAY_FRAMES = 300
Addon.FAILURE_LIMIT = 3
Addon.REGISTER_FRAMES = {1, 60, 180, 420, 900, 1800}
Addon.GAME_SHA256 = '2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E'
Addon.EXE_SHA256 = 'F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06'
Addon.MODE_NAMES = {'off', 'helmet matches armor', 'armor matches helmet'}

-- Whether two identities name the same Helldiver with the same kits and records (the cape aside: it matters only
-- with Recolor Cape on, see verify).
local function same_identity(a, b)
    return a.units_at == b.units_at and a.avatar == b.avatar and a.helmet == b.helmet and a.armor == b.armor
        and a.body == b.body and a.peer_low == b.peer_low and a.peer_high == b.peer_high and a.ui_slot == b.ui_slot
end

-- The instance: step() every frame, pause(reason), stopped(reason), set_option(name, value).
-- m: the modules and services {Avatar, Preview, Recolor, Engine, Files, Slim, Texture, Colour, Transfer, Matcher,
-- Kits, Schemes, Patches, Sync, Remote, memory, native, game, note, natives (PlayFab's, default Sync.natives)}; without
-- Preview
-- there is no UI preview target, without Sync and Remote no sync.
function Addon.new(m)
    local Avatar, Preview, Recolor, memory, note = m.Avatar, m.Preview, m.Recolor, m.memory, m.note
    local time = memory.time
    local state = {frame = 0, next_resolve = 0, next_verify = 0, next_check = 0, identity = nil, watch = nil, slot = nil,
                   dirty = false, job = nil, request = nil, failures = {}, why = nil, budget_end = 0,
                   options = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true, recolor_hoods = true,
                              match_materials = false, recolor_cape = false, scheme = 0},
                   next_sync = 0, loopback = false, holder = {}, status = 'starting'}
    local pool = Recolor.pool({Engine = m.Engine, native = m.native, memory = memory})
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
                      Transfer = m.Transfer, Matcher = m.Matcher, Kits = m.Kits, Schemes = m.Schemes, Capes = m.Capes,
                      memory = memory, wait = coroutine.yield,
                      game = m.game,
                      Cache = m.Cache, Appearance = m.Appearance,
                      cache_path = m.cache_path,
                      build = {exe_sha256 = Addon.EXE_SHA256, game_sha256 = Addon.GAME_SHA256}}
    -- Sync With Mod Users: the lobby session and the other players' recolors. Always on (the user, 2026-10-07: no
    -- option, every mod user shares and sees the others): this player's settings are shared from the start.
    local session = m.Sync and m.Remote and m.Sync.session({memory = memory, game = m.game, note = note,
                                                            natives = m.natives or m.Sync.natives})
    local remote = session and m.Remote.new({Avatar = Avatar, Recolor = Recolor, Engine = m.Engine, Sync = m.Sync,
                                             memory = memory, native = m.native, pool = pool, game = m.game,
                                             read = Avatar.reader(memory), note = note})
    state.syncing = session ~= nil
    state.sync_text = session and m.Sync.encode(state.options) or nil
    local self = {state = state, controller = controller, ui_controller = ui_controller, pool = pool, remote = remote,
                  session = session}

    local function maybe_yield()
        if time() >= state.budget_end then coroutine.yield() end
    end

    -- The local player's UI preview, located with the identity; kept while it is the same slot record.
    local function locate_ui(identity, frame)
        local where = Preview and Preview.locate(read, m.game, identity.ui_slot)
        local ui = state.ui
        if ui and where and ui.where.record == where.record then return end
        if ui then ui_controller.restore(frame) end
        state.ui = where and {where = where, watch = Preview.watch(memory, where), shown = false, dirty = false} or nil
    end

    local function adopt(identity, frame)
        identity = Avatar.copy(identity)
        state.identity, state.slot = identity, Avatar.preview_slot(memory, identity, read)
        state.watch = Avatar.watch(memory, identity, state.slot)
        state.watch.changed(true) -- keeps the current units and copies: later frames report only later changes
        state.next_verify, state.dirty = frame + Addon.VERIFY_FRAMES, true
        locate_ui(identity, frame)
        note(string.format('Local Helldiver: avatar %d, helmet %08x, armor %08x, body %d%s%s.', identity.avatar_index,
            identity.helmet, identity.armor, identity.body, state.slot and ', preview slot found' or '',
            state.ui and (', UI preview slot ' .. state.ui.where.slot) or ''))
    end

    local function lose(frame, why)
        state.identity, state.watch, state.slot = nil, nil, nil
        state.next_resolve = frame + Addon.RESOLVE_FRAMES
        controller.prune()
        if state.ui then
            ui_controller.restore(frame)
            state.ui = nil
        end
        if why ~= state.why then
            state.why = why
            note('No local Helldiver (' .. tostring(why) .. ').')
        end
    end

    local function resolve(frame)
        state.next_resolve = frame + Addon.RESOLVE_FRAMES
        local identity, why = Avatar.resolve(memory, m.game, read, probe)
        if identity then
            state.why = nil
            adopt(identity, frame)
        elseif why ~= state.why then
            state.why = why
            note('Waiting for the local Helldiver (' .. tostring(why) .. ').')
        end
    end

    local function request_key(r)
        return table.concat({r.mode, r.scheme, r.keep_sets and 1 or 0, r.keep_hoods and 1 or 0, r.materials and 1 or 0,
                             r.helmet, r.armor, r.body, r.capes and r.cape or 0}, ':')
    end

    -- The mode and paint scheme of a request for target: the options', except the avatar's in the test build's
    -- loopback (off: the sync path recolors it from the shared value, as it would another player).
    local function mode_of(target)
        if target == 'avatar' and state.loopback then return Recolor.OFF, 0 end
        return state.options.mode, state.options.scheme
    end

    -- Whether the options changed since request r was made (its result no longer applies; a new job follows).
    local function options_changed(r)
        local o = state.options
        local mode, scheme = mode_of(r.target)
        return mode ~= r.mode or scheme ~= r.scheme or o.keep_sets ~= r.keep_sets
            or (not o.recolor_hoods) ~= r.keep_hoods or o.match_materials ~= r.materials or o.recolor_cape ~= r.capes
    end

    -- Whether kits differ from the ones request r was made for (the cape counts only with Recolor Cape on).
    local function kits_changed(r, helmet, armor, body, cape)
        return helmet ~= r.helmet or armor ~= r.armor or body ~= r.body or (r.capes and cape ~= r.cape)
    end

    -- New units of the same Helldiver, kits and options (a respawn, a body copy): the applied result is bound to
    -- them at once, as its job would (no job, no resolve: verify has just resolved the identity). False when there
    -- is no such result (a job then).
    -- Whether a result was made of the kit records as they read now (signatures, src/recolor.lua): a transmog mod
    -- recomposes a record at runtime under the same id (its carrier; KB match-your-colors-review-transmog-v13), and
    -- the new units then show other pieces. Read through the job's catalogue (no pause); without one, false.
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

    local function rebind(frame)
        local result, request, id = controller.result, state.applied, state.identity
        if not result or not request or state.dirty or options_changed(request)
            or kits_changed(request, id.helmet, id.armor, id.body, id.cape)
            or not records_same(result, id.helmet, id.armor, request.capes and id.cape or nil) then
            return false
        end
        controller.apply(result, state.identity, state.slot, frame)
        return true
    end

    -- Resolves the local player again: a different Helldiver, kits or preview slot is adopted (a change);
    -- changed: the units already differ, so the same identity's result is bound to the new ones (a job when there is
    -- none) and dead units' bindings dropped. Another cape needs a job only with Recolor Cape on; it is kept current
    -- either way, so turning the option on recolors the cape worn then.
    local function verify(frame, changed)
        state.next_verify = frame + Addon.VERIFY_FRAMES
        local identity, why = Avatar.resolve(memory, m.game, read, probe)
        if not identity then return lose(frame, why) end
        local slot = Avatar.preview_slot(memory, identity, read)
        local rebound = false -- an apply prunes dead units' bindings itself
        if not same_identity(identity, state.identity) or slot ~= state.slot then
            adopt(identity, frame)
        elseif state.options.recolor_cape and identity.cape ~= state.identity.cape then
            state.dirty = true
        elseif changed then
            rebound = rebind(frame)
            state.dirty = state.dirty or not rebound
        end
        state.identity.cape = identity.cape
        if changed and not rebound and #controller.bindings > 0 then controller.prune() end
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

    -- Applies a result with `ctl`; the count, the apply's time in ms and how many textures had to be made.
    local function timed_apply(ctl, result, identity, slot, frame)
        local made, started = pool.made, time()
        local count = ctl.apply(result, identity, slot, frame)
        return count, (time() - started) * 1000, pool.made - made
    end

    -- A cape plan's development line (src/recolor.lua cape_report), once per plan.
    local function note_cape(result)
        if result.cape_report and result.cape_report ~= state.cape_report then
            note(result.cape_report)
            state.cape_report = result.cape_report
        end
    end

    -- The log lines of an applied result (applied: the apply's ms and the textures it made).
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
            .. 'slice %.1f ms in %s, heap %+.0f KB; applied in %.2f ms, %d new textures).', count, how, luts,
            job.work * 1000, job.frames, job.longest * 1000, tostring(job.longest_stage), job.heap_kb, applied.ms,
            applied.made))
        note_cape(result)
        if reader and reader.reads > 0 then
            note(string.format('Game data read so far: %d reads, %.1f MB, longest read %.1f ms (%d KB), %d frames '
                .. 'waited on the disk.', reader.reads, reader.bytes / 1048576, reader.longest * 1000,
                reader.longest_size / 1024, reader.waits or 0))
        end
    end

    -- A UI preview job's result, applied when the preview still shows its kits with the same options (else a
    -- new job follows).
    local function finish_ui(result, request, frame, reader)
        local ui = state.ui
        if not ui or not ui.shown then return end
        if kits_changed(request, ui.helmet, ui.armor, ui.body, ui.cape) or options_changed(request) then
            ui.dirty = true
            return
        end
        local key = ui_controller.key
        local count, ms, made = timed_apply(ui_controller, result, {units_at = ui.where.units_at, body = request.body},
                                            nil, frame)
        ui.applied = request -- what ui_controller.result was made for (poll_ui's rebind)
        if reader then note_cache(reader, frame) end
        if result.action == 'apply' and (count > 0 or result.key ~= key) then
            local job = state.last_job
            note(string.format('Preview recolored: %d materials (helmet %08x, armor %08x; job %.1f ms of work over %d '
                .. 'frames, longest slice %.1f ms; applied in %.2f ms, %d new textures).', count, request.helmet,
                request.armor, job.work * 1000, job.frames, job.longest * 1000, ms, made))
        end
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

    local function finish(ok, result, frame)
        local request = state.request
        state.job, state.request = nil, nil
        local reader = state.holder.pipeline
        if reader then reader.close() end -- the game-data reader and its buffers live only during a job
        state.last_job = {seconds = time() - state.job_started, frames = frame - state.job_frame + 1,
                          work = state.job_work, longest = state.job_slice, longest_stage = state.job_slice_stage,
                          heap_kb = gcinfo() - state.job_heap}
        if request.target == 'remote' then -- another mod user's Helldiver: its entry counts its own failures
            remote.finish(ok, result, request, frame)
            if ok and reader then note_cache(reader, frame) end
            return
        end
        local key = request_key(request)
        if not ok then
            state.failures[key] = (state.failures[key] or 0) + 1
            state.status = 'failed: ' .. tostring(result)
            note('Recolor failed (' .. state.failures[key] .. '/' .. Addon.FAILURE_LIMIT .. '): ' .. tostring(result))
            return
        end
        if request.target == 'ui' then return finish_ui(result, request, frame, reader) end
        local now = still_current(request, frame)
        if not now then return end
        local count, ms, made = timed_apply(controller, result, now, Avatar.preview_slot(memory, now, read), frame)
        state.applied = request -- what controller.result was made for (rebind)
        if reader then note_cache(reader, frame) end
        state.status = result.action == 'apply' and 'active' or ('vanilla: ' .. tostring(result.reason))
        log_result(result, request, count, reader, {ms = ms, made = made})
        state.last_reason = result.reason
    end

    -- One slice of the running job. A job that ended after using more than half its budget this frame is applied on
    -- the next frame (the apply, and a texture the pool has to make, then has a frame to itself); a short one at once.
    local function run_job(frame)
        if state.ended then
            local ok, result = state.ended_ok, state.ended_result
            state.ended, state.ended_result = false, nil
            return finish(ok, result, frame)
        end
        local started = time()
        state.budget_end = started + Addon.BUDGET
        local ok, result = coroutine.resume(state.job)
        local slice = time() - started
        state.job_work = state.job_work + slice
        if slice > state.job_slice then state.job_slice, state.job_slice_stage = slice, state.holder.stage end
        if coroutine.status(state.job) ~= 'dead' then return end
        if slice > Addon.BUDGET / 2 then
            state.ended, state.ended_ok, state.ended_result = true, ok, result
            return
        end
        finish(ok, result, frame)
    end

    -- The request for a target ('avatar', 'ui' or 'remote'), or nil (a preview not showing two kits yet, no other
    -- mod user's Helldiver waiting).
    local function request_for(target)
        if target == 'remote' then return remote.request() end
        local o = state.options
        local mode, scheme = mode_of(target)
        local request = {target = target, mode = mode, scheme = scheme, keep_sets = o.keep_sets,
                         keep_hoods = not o.recolor_hoods, materials = o.match_materials, capes = o.recolor_cape}
        if target == 'ui' then
            local ui = state.ui
            ui.dirty = false
            if not ui.helmet or ui.helmet == 0 or ui.armor == 0 then return nil end
            request.helmet, request.armor, request.body, request.cape = ui.helmet, ui.armor, ui.body, ui.cape
            return request
        end
        state.dirty = false
        local id = state.identity
        request.helmet, request.armor, request.body, request.cape = id.helmet, id.armor, id.body, id.cape
        return request
    end

    local function start_job(frame, target)
        local request = request_for(target)
        if not request then return end
        if target ~= 'remote' and (state.failures[request_key(request)] or 0) >= Addon.FAILURE_LIMIT then return end
        state.request = request
        state.job_started, state.job_frame, state.job_work, state.job_slice = time(), frame, 0, 0
        state.job_heap = gcinfo() -- the Lua heap in KB (read only)
        state.job = coroutine.create(function()
            return Recolor.job(job_deps, state.holder, request, maybe_yield)
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
    end

    -- The UI preview's check: a second check this frame, of other memory than the avatar's (the preview's own
    -- units and kits); on 1 frame in UI_GATE_FRAMES while it is not shown, every frame while it is.
    local function poll_ui(frame)
        local ui = state.ui
        local status = ui.watch.poll()
        if status == 'absent' then
            if ui.shown then
                ui.shown, ui.dirty = false, false
                ui.helmet, ui.armor, ui.body, ui.cape = nil, nil, nil, nil -- shown again: a job for its new units
                ui_controller.restore(frame)
            end
            return
        end
        ui.shown = true
        if status == 'kits' then
            local helmet, armor, body, cape = ui.watch.kits()
            -- a new job only for kits that matter (a cape shown counts only with Recolor Cape on)
            if helmet ~= ui.helmet or armor ~= ui.armor or body ~= ui.body
                or (state.options.recolor_cape and cape ~= ui.cape) then
                ui.dirty = true
            end
            ui.helmet, ui.armor, ui.body, ui.cape = helmet, armor, body, cape
        elseif status == 'units' then
            -- the same plan binds the new units: at once when it is applied for these kits and options, else a job
            local r = ui.applied
            if ui.dirty or not ui_controller.result or not r or options_changed(r)
                or kits_changed(r, ui.helmet, ui.armor, ui.body, ui.cape)
                or not records_same(ui_controller.result, ui.helmet, ui.armor, r.capes and ui.cape or nil) then
                ui.dirty = true
            else
                ui_controller.apply(ui_controller.result, {units_at = ui.where.units_at, body = r.body}, nil, frame)
            end
        end
    end

    -- The UI preview's check when due, then a job when one is needed (the avatar's first).
    local function preview_and_jobs(frame)
        local ui = state.ui
        if ui and (ui.shown or frame % Addon.UI_GATE_FRAMES == 0) then poll_ui(frame) end
        if state.dirty and state.identity then
            start_job(frame, 'avatar')
        elseif state.ui and state.ui.dirty then
            start_job(frame, 'ui')
        end
    end

    -- The lobby poll: this player's value posted when due, the members' values to the other players' recolors.
    local function poll_sync(frame)
        state.next_sync = frame + m.Sync.POLL_FRAMES
        remote.update(frame, session.poll(frame, state.sync_text, state.loopback))
    end

    -- Sync With Mod Users, on a frame with no recolor job and no cache save: a second check this frame, of other
    -- memory than the local player's, because the squad's lobby and the other players' Helldivers change on their
    -- own. The lobby poll every Sync.POLL_FRAMES frames; while another player's Helldiver is recolored (or its
    -- textures retire), one unit watch on 1 frame in Remote.WATCH_FRAMES, else one binding check every CHECK_FRAMES
    -- frames and a job when one is due. Each frame does one of them at most; the calls into interpreted code are
    -- behind these compares.
    local WATCH_FRAMES = m.Remote and m.Remote.WATCH_FRAMES
    local function sync_step(frame)
        if frame >= state.next_sync and state.verified_at ~= frame then return poll_sync(frame) end
        if remote.order[1] == nil and remote.retiring[1] == nil then return end
        if frame % WATCH_FRAMES == 0 then return remote.step(frame) end
        if frame % Addon.CHECK_FRAMES == 1 then return remote.check() end
        if remote.pending then start_job(frame, 'remote') end
    end

    -- The local Helldiver's checks and jobs: true when this frame resolved it, ran a recolor job or saved the cache
    -- (then nothing else runs this frame).
    local function local_step(frame)
        if not state.identity then
            if frame < state.next_resolve then return false end
            resolve(frame)
            return true
        end
        local changed = state.watch.changed(frame % 2 == 1) -- the body-copy slot on odd frames (UI gate: frame % 4 == 0)
        -- One heavy periodic piece per frame: a chain check (about 20 reads) moves the binding check to the next
        -- frame, and the cache save slice and the lobby poll wait a frame too (sync_step: verified_at).
        local verified = changed or frame >= state.next_verify
        if verified then
            verify(frame, changed)
            state.verified_at = frame
        elseif frame >= state.next_check then
            check_bindings(frame)
        end
        preview_and_jobs(frame)
        if state.job_frame == frame then return true end -- a recolor job started (and maybe ended) this frame
        -- A second piece of work this frame only when the cache save is due and neither a recolor job nor a chain
        -- check ran this frame.
        if verified or not (state.save_at and frame >= state.save_at) then return false end
        save_step(frame)
        return true
    end

    -- Every frame, before the game's update.
    function self.step()
        local frame = state.frame + 1
        state.frame = frame
        if controller.retired[1] then controller.collect(frame) end
        if ui_controller.retired[1] then ui_controller.collect(frame) end
        if state.job then return run_job(frame) end
        -- The lobby only while the local Helldiver exists (not on the title screen, while loading or dead): the lobby
        -- is settled then (its first post crashed the game on arrival on the ship, 2026-10-07: src/sync.lua).
        if local_step(frame) or not state.syncing or not state.identity then return end
        sync_step(frame)
    end

    -- An option from Mod Options Menu (or its default): mode (1-3), scheme (0 none, 1 to the schemes' count) or one
    -- of the toggles.
    local TOGGLES = {keep_sets = true, recolor_hoods = true, match_materials = true, recolor_cape = true}
    local SCHEMES = m.Schemes and #m.Schemes.LIST or 0
    local function valid(name, value)
        if name == 'mode' then return value == 1 or value == 2 or value == 3 end
        if name == 'scheme' then
            return type(value) == 'number' and value % 1 == 0 and value >= 0 and value <= SCHEMES
        end
        return TOGGLES[name] == true and type(value) == 'boolean'
    end
    function self.set_option(name, value)
        if not valid(name, value) then return end
        local o = state.options
        o[name] = value
        note('Option ' .. name .. ' = ' .. tostring(value) .. '.')
        if session then state.sync_text = m.Sync.encode(o) end -- posted once it has settled (src/sync.lua)
        state.dirty = true
        if state.ui and state.ui.shown then state.ui.dirty = true end
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
    function self.pause(reason)
        state.job, state.request, state.ended, state.ended_result = nil, nil, false, nil
        if state.saving then -- an unfinished save starts over later
            state.saving = nil
            if state.holder.pipeline then state.holder.pipeline.dirty = true end
        end
        if state.holder.pipeline then state.holder.pipeline.close() end
        if m.Files then m.Files.settle() end -- a read the dropped job left in flight
        controller.restore(state.frame)
        ui_controller.restore(state.frame)
        if remote then -- the next lobby poll after a resume finds the other players again
            remote.clear(state.frame)
            state.next_sync = 0
        end
        state.identity, state.watch, state.slot, state.ui, state.next_resolve = nil, nil, nil, nil, 0
        state.status = 'paused: ' .. tostring(reason)
        note('Paused (' .. tostring(reason) .. '); original colors until the addon resumes.')
    end

    -- At shutdown: a cache save still due (or under way) is written at once; the game is closing.
    local function save_at_shutdown()
        local reader = state.holder.pipeline
        if not (reader and (state.saving or state.save_at)) then return end
        if state.saving then reader.dirty = true end
        local ok, saved, why = pcall(reader.save)
        note(ok and saved and 'Analysis cache saved at shutdown.'
             or ('Analysis cache not saved: ' .. tostring(ok and why or saved)))
    end

    -- The guard's stop: original colors back, except at shutdown (the game is closing).
    function self.stopped(reason)
        if reason == 'shutdown' then
            save_at_shutdown()
            note('Shutdown: ' .. state.status .. string.format(' (applied %d, restored %d; textures made %d, '
                .. 'refilled %d, destroyed %d', controller.applied, controller.restored, pool.made, pool.refilled,
                pool.destroyed) .. (session and string.format('; sync: %d posts, %d failed, other players recolored '
                .. '%d times', session.posts, session.failures, remote.jobs) or '') .. ').')
            return
        end
        state.job, state.ended, state.ended_result = nil, false, nil
        if state.holder.pipeline then pcall(state.holder.pipeline.close) end
        if m.Files then pcall(m.Files.settle) end -- a read the dropped job left in flight
        local ok, problem = pcall(controller.restore, state.frame)
        local ui_ok, ui_problem = pcall(ui_controller.restore, state.frame)
        if ok and not ui_ok then problem = ui_problem end
        if remote then
            local remote_ok, remote_problem = pcall(remote.clear, state.frame)
            if not remote_ok then ok, problem = false, remote_problem end
        end
        note('Stopped (' .. tostring(reason) .. ')' .. ((ok and ui_ok) and '' or ('; ' .. tostring(problem))))
    end

    -- Everything but the frame step (with the UI preview's and sync's per-frame gates), the idle check and the
    -- job's yield runs on few frames: interpreted.
    if type(jit) == 'table' and type(jit.off) == 'function' then
        for _, fn in ipairs({locate_ui, adopt, lose, resolve, record_same, records_same, rebind, verify, request_key,
                             mode_of, options_changed, kits_changed,
                             note_cache, timed_apply, log_result, finish_ui, still_current, finish, run_job,
                             request_for, start_job, save_step, check_bindings, poll_sync, valid,
                             self.set_option, self.set_loopback, self.pause, save_at_shutdown, self.stopped}) do
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
}

-- The scheme of a Paint Scheme menu value (1 Off, 2-12 the schemes), or nil.
local function scheme_of(value)
    return type(value) == 'number' and value - 1 or nil
end

-- Mod Options Menu registration: the mode choice, the paint scheme choice (with Schemes, src/schemes.lua) and the
-- toggles (complete sets, hoods, materials, cape), registered once the menu's table exists (the loader's
-- after_startup event, else a few early frames). tr: the translator.
function Addon.options(instance, tr, note, Schemes)
    local registered, attempts = false, 0
    local function text(menu, key)
        if (tonumber(menu.version) or 1) >= 2 then return function() return tr(key) end end
        return tr(key)
    end
    local function register_scheme(menu, mod)
        local choices = {'Off'}
        for _, scheme in ipairs(Schemes.LIST) do choices[#choices + 1] = text(menu, scheme.text) end
        return menu.register_option(Addon.OPTION_SCHEME, {type = 'choice', mod = mod, mod_id = Addon.MOD_ID,
            label = text(menu, 'option.scheme.label'), description = text(menu, 'option.scheme.description'),
            choices = choices, default = 1})
    end
    local function register(menu)
        local mod = text(menu, 'option.mod')
        local ok, why = menu.register_option(Addon.OPTION_MODE, {type = 'choice', mod = mod, mod_id = Addon.MOD_ID,
            label = text(menu, 'option.mode.label'), description = text(menu, 'option.mode.description'),
            choices = {'Off', text(menu, 'option.mode.helmet'), text(menu, 'option.mode.armor')}, default = 2})
        if not ok then return false, why end
        if Schemes then
            ok, why = register_scheme(menu, mod)
            if not ok then return false, why end
        end
        for _, toggle in ipairs(Addon.TOGGLES) do
            ok, why = menu.register_option(toggle[1], {type = 'toggle', mod = mod, mod_id = Addon.MOD_ID,
                label = text(menu, toggle[3]), description = text(menu, toggle[4]), default = toggle[5]})
            if not ok then return false, why end
        end
        instance.set_option('mode', menu.get(Addon.OPTION_MODE))
        menu.on_change(Addon.OPTION_MODE, function(value) instance.set_option('mode', value) end)
        if Schemes then
            instance.set_option('scheme', scheme_of(menu.get(Addon.OPTION_SCHEME)))
            menu.on_change(Addon.OPTION_SCHEME, function(value) instance.set_option('scheme', scheme_of(value)) end)
        end
        for _, toggle in ipairs(Addon.TOGGLES) do
            local id, name = toggle[1], toggle[2]
            instance.set_option(name, menu.get(id))
            menu.on_change(id, function(value) instance.set_option(name, value) end)
        end
        return true
    end
    local self = {}
    -- One attempt; true once registered (or when no menu is installed: defaults stay).
    function self.attempt()
        if registered then return true end
        attempts = attempts + 1
        local menu = rawget(_G, 'ModOptionsMenu')
        if type(menu) ~= 'table' or menu.api ~= 1 then return false end
        local called, ok, why = pcall(register, menu)
        registered = called and ok
        if registered then
            note('Mod Options Menu: options registered.')
        else
            note('Mod Options Menu: not registered (' .. tostring(called and why or ok) .. ').')
        end
        return registered
    end
    -- True on the frames of Addon.REGISTER_FRAMES until registered; afterwards one compare per frame.
    local next_index, next_at = 1, Addon.REGISTER_FRAMES[1]
    function self.due(frame)
        if frame < next_at or registered then return false end
        next_index = next_index + 1
        next_at = Addon.REGISTER_FRAMES[next_index] or math.huge
        return true
    end
    function self.registered() return registered end
    return self
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
        return Addon.new({Avatar = m.Avatar, Preview = m.Preview, Recolor = m.Recolor, Engine = m.Engine,
                          Files = m.Files, Slim = m.Slim,
                          Texture = m.Texture, Colour = m.Colour, Transfer = m.Transfer, Matcher = m.Matcher,
                          Kits = m.Kits, Schemes = m.Schemes, Capes = m.Capes, Patches = m.Patches, Sync = m.Sync,
                          Remote = m.Remote,
                          memory = memory,
                          Appearance = m.Appearance and m.AppearanceData and m.Appearance.new(m.AppearanceData),
                          native = native, game = memory.address(game), note = note, Cache = m.Cache,
                          cache_path = m.Cache and m.Cache.path(loader)})
    end)
    if not ready then
        note('Disabled: ' .. tostring(instance))
        return nil
    end
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
    for _, fn in ipairs({same_identity, scheme_of, Addon.options, Addon.loader_ok, Addon.install}) do
        jit.off(fn, true)
    end
end

return Addon
