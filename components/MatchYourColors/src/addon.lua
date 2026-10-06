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
--     the UI preview has been closed for SAVE_DELAY_FRAMES frames, at shutdown at the latest.
-- No memory writes: the recolor goes through engine calls (src/engine.lua).
local ffi = require('ffi')

local Addon = {VERSION = '1.2'}
Addon.REVISION = 'v' .. Addon.VERSION
Addon.MOD_ID = 'cowboybingus.match_your_colors'
Addon.OPTION_MODE = 'cowboybingus.match_your_colors.mode'
Addon.OPTION_SETS = 'cowboybingus.match_your_colors.keep_sets'
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

-- Whether two identities name the same Helldiver with the same kits and records.
local function same_identity(a, b)
    return a.units_at == b.units_at and a.avatar == b.avatar and a.helmet == b.helmet and a.armor == b.armor
        and a.body == b.body and a.peer_low == b.peer_low and a.peer_high == b.peer_high and a.ui_slot == b.ui_slot
end

-- The instance: step() every frame, pause(reason), stopped(reason), set_option(name, value).
-- m: the modules and services {Avatar, Preview, Recolor, Engine, Files, Slim, Texture, Colour, Transfer, Matcher,
-- Kits, memory, native, game, note}; without Preview there is no UI preview target.
function Addon.new(m)
    local Avatar, Preview, Recolor, memory, note = m.Avatar, m.Preview, m.Recolor, m.memory, m.note
    local time = memory.time
    local state = {frame = 0, next_resolve = 0, next_verify = 0, next_check = 0, identity = nil, watch = nil, slot = nil,
                   dirty = false, job = nil, request = nil, failures = {}, why = nil, budget_end = 0,
                   options = {mode = Recolor.HELMET_FROM_ARMOR, keep_sets = true}, holder = {}, status = 'starting'}
    local pool = Recolor.pool({Engine = m.Engine, native = m.native, memory = memory})
    local controller = Recolor.controller({Engine = m.Engine, Avatar = Avatar, memory = memory, native = m.native,
                                           pool = pool})
    -- The UI preview's units are other units than the avatar's, showing maybe another pair: own textures and
    -- bindings, from the same pool.
    local ui_controller = Recolor.controller({Engine = m.Engine, Avatar = Avatar, memory = memory, native = m.native,
                                              pool = pool})
    local read = Avatar.reader(memory) -- one buffer for every resolve
    local probe = {} -- the identity table every check refills; adopted identities are copies
    local job_deps = {Files = m.Files, Slim = m.Slim, Texture = m.Texture, Colour = m.Colour, Transfer = m.Transfer,
                      Matcher = m.Matcher, Kits = m.Kits, memory = memory, game = m.game, Cache = m.Cache,
                      Appearance = m.Appearance,
                      cache_path = m.cache_path,
                      build = {exe_sha256 = Addon.EXE_SHA256, game_sha256 = Addon.GAME_SHA256}}
    local self = {state = state, controller = controller, ui_controller = ui_controller, pool = pool}

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
        state.watch.changed() -- keeps the current units: later frames report only later changes
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

    -- Resolves the local player again: a different Helldiver, kits or preview slot is adopted (a change);
    -- changed: the units already differ, so the same identity needs a new job too.
    local function verify(frame, changed)
        state.next_verify = frame + Addon.VERIFY_FRAMES
        local identity, why = Avatar.resolve(memory, m.game, read, probe)
        if not identity then return lose(frame, why) end
        local slot = Avatar.preview_slot(memory, identity, read)
        if not same_identity(identity, state.identity) or slot ~= state.slot then
            adopt(identity, frame)
        elseif changed then
            state.dirty = true
        end
        if #controller.bindings > 0 then controller.prune() end
    end

    local function request_key(r)
        return table.concat({r.mode, r.keep_sets and 1 or 0, r.helmet, r.armor, r.body}, ':')
    end

    -- After applying: the cache status once; new analyses are written later by the save job (save_step).
    local function note_cache(reader, frame)
        if reader.cache_status and not state.cache_logged then
            state.cache_logged = true
            note('Analysis cache: ' .. reader.cache_status .. '.')
        end
        if reader.dirty then state.save_at = frame + Addon.SAVE_DELAY_FRAMES end
    end

    -- Applies a result with `ctl`; the count, the apply's time in ms and how many textures had to be made.
    local function timed_apply(ctl, result, identity, slot, frame)
        local made, started = pool.made, time()
        local count = ctl.apply(result, identity, slot, frame)
        return count, (time() - started) * 1000, pool.made - made
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
        note(string.format('Recolored %d materials (%s, %d LUTs; job %.1f ms of work over %d frames, longest '
            .. 'slice %.1f ms in %s, heap %+.0f KB; applied in %.2f ms, %d new textures).', count,
            Addon.MODE_NAMES[request.mode], luts, job.work * 1000, job.frames, job.longest * 1000,
            tostring(job.longest_stage), job.heap_kb, applied.ms, applied.made))
        if reader and reader.reads > 0 then
            note(string.format('Game data read so far: %d reads, %.1f MB, longest read %.1f ms (%d KB).',
                reader.reads, reader.bytes / 1048576, reader.longest * 1000, reader.longest_size / 1024))
        end
    end

    -- A UI preview job's result, applied when the preview still shows its kits with the same options (else a
    -- new job follows).
    local function finish_ui(result, request, frame, reader)
        local ui, o = state.ui, state.options
        if not ui or not ui.shown then return end
        if ui.helmet ~= request.helmet or ui.armor ~= request.armor or ui.body ~= request.body
            or o.mode ~= request.mode or o.keep_sets ~= request.keep_sets then
            ui.dirty = true
            return
        end
        local key = ui_controller.key
        local count, ms, made = timed_apply(ui_controller, result, {units_at = ui.where.units_at, body = request.body},
                                            nil, frame)
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
        if now.helmet ~= request.helmet or now.armor ~= request.armor or now.body ~= request.body then
            return adopt(now, frame)
        end
        local o = state.options
        if o.mode ~= request.mode or o.keep_sets ~= request.keep_sets then
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
        if reader then note_cache(reader, frame) end
        state.status = result.action == 'apply' and 'active' or ('vanilla: ' .. tostring(result.reason))
        log_result(result, request, count, reader, {ms = ms, made = made})
        state.last_reason = result.reason
    end

    local function run_job(frame)
        local started = time()
        state.budget_end = started + Addon.BUDGET
        local ok, result = coroutine.resume(state.job)
        local slice = time() - started
        state.job_work = state.job_work + slice
        if slice > state.job_slice then state.job_slice, state.job_slice_stage = slice, state.holder.stage end
        if coroutine.status(state.job) ~= 'dead' then return end
        finish(ok, result, frame)
    end

    -- The request for a target ('avatar' or 'ui'), or nil (a preview not showing two kits yet).
    local function request_for(target)
        local o = state.options
        if target == 'ui' then
            local ui = state.ui
            ui.dirty = false
            if ui.helmet == 0 or ui.armor == 0 then return nil end
            return {target = 'ui', mode = o.mode, keep_sets = o.keep_sets, helmet = ui.helmet, armor = ui.armor,
                    body = ui.body}
        end
        state.dirty = false
        local id = state.identity
        return {target = 'avatar', mode = o.mode, keep_sets = o.keep_sets, helmet = id.helmet, armor = id.armor,
                body = id.body}
    end

    local function start_job(frame, target)
        local request = request_for(target)
        if not request or (state.failures[request_key(request)] or 0) >= Addon.FAILURE_LIMIT then return end
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
                ui_controller.restore(frame)
            end
            return
        end
        ui.shown = true
        if status == 'kits' then
            ui.helmet, ui.armor, ui.body = ui.watch.kits()
            ui.dirty = true
        elseif status == 'units' then
            ui.dirty = true -- the same plan binds the new units
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

    -- Every frame, before the game's update.
    function self.step()
        local frame = state.frame + 1
        state.frame = frame
        if controller.retired[1] then controller.collect(frame) end
        if ui_controller.retired[1] then ui_controller.collect(frame) end
        if state.job then return run_job(frame) end
        if not state.identity then
            if frame >= state.next_resolve then resolve(frame) end
            return
        end
        local changed = state.watch.changed()
        if changed or frame >= state.next_verify then verify(frame, changed) end
        if frame >= state.next_check then check_bindings(frame) end
        preview_and_jobs(frame)
        -- A second piece of work this frame only when the cache save is due and no recolor job ran this frame.
        if state.save_at and frame >= state.save_at and not state.job and state.job_frame ~= frame then
            save_step(frame)
        end
    end

    -- An option from Mod Options Menu (or its default).
    function self.set_option(name, value)
        if name == 'mode' and (value == 1 or value == 2 or value == 3) then
            state.options.mode = value
        elseif name == 'keep_sets' and type(value) == 'boolean' then
            state.options.keep_sets = value
        else
            return
        end
        state.dirty = true
        if state.ui and state.ui.shown then state.ui.dirty = true end
        note('Option ' .. name .. ' = ' .. tostring(value) .. '.')
    end

    -- The guard's pause (an update below this addon failed): original colors back, job dropped; a resume
    -- starts again from a fresh resolve.
    function self.pause(reason)
        state.job, state.request = nil, nil
        if state.saving then -- an unfinished save starts over later
            state.saving = nil
            if state.holder.pipeline then state.holder.pipeline.dirty = true end
        end
        if state.holder.pipeline then state.holder.pipeline.close() end
        controller.restore(state.frame)
        ui_controller.restore(state.frame)
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
                .. 'refilled %d, destroyed %d).', controller.applied, controller.restored, pool.made, pool.refilled,
                pool.destroyed))
            return
        end
        state.job = nil
        local ok, problem = pcall(controller.restore, state.frame)
        local ui_ok, ui_problem = pcall(ui_controller.restore, state.frame)
        if ok and not ui_ok then problem = ui_problem end
        note('Stopped (' .. tostring(reason) .. ')' .. ((ok and ui_ok) and '' or ('; ' .. tostring(problem))))
    end

    -- Everything but the frame step, the idle check and the job's yield runs on few frames: interpreted.
    if type(jit) == 'table' and type(jit.off) == 'function' then
        for _, fn in ipairs({locate_ui, adopt, lose, resolve, verify, request_key, note_cache, timed_apply, log_result,
                             finish_ui, still_current, finish, run_job, request_for, start_job, save_step,
                             check_bindings, self.set_option, self.pause, save_at_shutdown, self.stopped}) do
            jit.off(fn, true)
        end
    end
    return self
end

-- Mod Options Menu registration: the mode choice and the complete-set toggle, registered once the menu's
-- table exists (the loader's after_startup event, else a few early frames). tr: the translator.
function Addon.options(instance, tr, note)
    local registered, attempts = false, 0
    local function text(menu, key)
        if (tonumber(menu.version) or 1) >= 2 then return function() return tr(key) end end
        return tr(key)
    end
    local function register(menu)
        local mod = text(menu, 'option.mod')
        local ok, why = menu.register_option(Addon.OPTION_MODE, {type = 'choice', mod = mod, mod_id = Addon.MOD_ID,
            label = text(menu, 'option.mode.label'), description = text(menu, 'option.mode.description'),
            choices = {'Off', text(menu, 'option.mode.helmet'), text(menu, 'option.mode.armor')}, default = 2})
        if not ok then return false, why end
        ok, why = menu.register_option(Addon.OPTION_SETS, {type = 'toggle', mod = mod, mod_id = Addon.MOD_ID,
            label = text(menu, 'option.sets.label'), description = text(menu, 'option.sets.description'),
            default = true})
        if not ok then return false, why end
        instance.set_option('mode', menu.get(Addon.OPTION_MODE))
        instance.set_option('keep_sets', menu.get(Addon.OPTION_SETS))
        menu.on_change(Addon.OPTION_MODE, function(value) instance.set_option('mode', value) end)
        menu.on_change(Addon.OPTION_SETS, function(value) instance.set_option('keep_sets', value) end)
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
-- locales, Avatar, Preview, Recolor, Engine, Files, Slim, Texture, Colour, Transfer, Matcher, Kits, env}. Returns the
-- instance, or nil when disabled.
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
                          Kits = m.Kits, memory = memory,
                          Appearance = m.Appearance and m.AppearanceData and m.Appearance.new(m.AppearanceData),
                          native = native, game = memory.address(game), note = note, Cache = m.Cache,
                          cache_path = m.Cache and m.Cache.path(loader)})
    end)
    if not ready then
        note('Disabled: ' .. tostring(instance))
        return nil
    end
    local tr = m.T.new(m.locales.en, m.locales.bundled, function(message) note('text: ' .. message) end)
    local options = Addon.options(instance, tr, note)
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
    for _, fn in ipairs({same_identity, Addon.options, Addon.loader_ok, Addon.install}) do jit.off(fn, true) end
end

return Addon
