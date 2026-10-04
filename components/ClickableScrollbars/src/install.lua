-- The runtime the loader starts: presses, held drags, the log and the error
-- policy, in the game's update callback.
local module, cs = ...
local clamp, DEFAULTS, keep_interpreted, runtime = cs.clamp, cs.DEFAULTS, cs.keep_interpreted, cs.runtime

-- ------------------------------------------------------------------ install

-- The native route needs only a reader: the addon builds that itself with the
-- same FFI surface the shipped Armory mods use, and the loader may hand one in.
-- The armory grid exists only while its screen does, so this first attempt is
-- for the log; the press path retries through refresh_native.
local function attach_native(state, platform)
    if state.bridge and state.bridge.api then
        state.native_api = state.bridge.api
    else
        local ok, api, reason = pcall(module.native_api)
        if ok and type(api) == 'table' then
            state.native_api = api
        else
            state.native_reason = tostring(reason or api)
        end
    end
    state.native_api_attempted = true
    if state.native_api then
        state.native, state.native_reason = module.native_locate(state.native_api)
        state.native_try = platform.now()
        if state.native then
            state.native_model, state.native_state_reason = module.native_state(state.native)
        end
    end
end

-- Error-free frames that end a burst of frame errors (about a minute at 60 FPS).
local ERROR_BURST_FRAMES = 3600

function module.install(create_platform, environment)
    local environment = environment or _G
    local loader = rawget(environment, 'CowboyBingusModLoader')
    if type(loader) ~= 'table' or (loader.api or 0) < 1 then
        return nil, 'Bingus Shared Loader API 1 is required'
    end
    if rawget(environment, 'ClickableScrollbars') then
        return nil, 'already installed'
    end
    if type(environment.update) ~= 'function' then
        return nil, 'game update callback unavailable'
    end

    local state = {
        revision = module.revision, status = 'starting', settings = module.parse_settings(nil, DEFAULTS),
        clicks = 0, pages = 0, drags = 0, corrections = 0, no_response = 0, misses = 0, skipped = 0,
        capture_failures = 0, errors = 0, burst_errors = 0, frames = 0, down_frames = 0, frame_clicks = 0,
        last_key = 0,
        wheel_units = 0, drag_notches = 0, drag_active = false,
        captures = 0, dumps = 0, last_dump = nil,
        wide_retries = 0, capture_fallbacks = 0,
        geometry_failures = 0, geometry_failed = false,
        emit_clamps = 0,
        settle_budget_skips = 0, frame_interval_ms = nil, effective_budget_ms_per_s = nil,
        drag_verifies = 0, drag_stalls = 0, drag_limits = 0, drag_out = 0, drag_rejects = 0,
        drag_resyncs = 0,
        track_top = nil, track_bottom = nil, track_column = nil, track_blocked = 0,
        track_drops = 0, drag_foreground_pauses = 0,
        burst_skips = 0, budget_skips = 0, capture_window_start = nil, capture_window_ms = 0,
        frame_ms_total = 0, frame_ms_max = 0, capture_ms_total = 0, capture_ms_max = 0,
        dirty = true, last_reason = 'start', last_direction = nil, last_bar = nil, last_notches = 0,
        last_delta = nil, last_moved = nil, last_luminance = nil, last_background = nil,
        last_click_luma = nil, last_bar_luma = nil,
        last_thumb_masked = nil, bar_cache = nil, last_error = nil,
        pixels_per_notch = nil, calibration = {},
    }
    rawset(environment, 'ClickableScrollbars', state)

    local function read_settings()
        local base = os.getenv('LOCALAPPDATA')
        if not base then return state.settings end
        local path = base .. '/ClickableScrollbars'
        local file = io.open(path .. '/ClickableScrollbars.ini', 'rb')
        if not file then return state.settings end
        local text = file:read(4096)
        file:close()
        return module.parse_settings(text, DEFAULTS)
    end

    local created, platform = pcall(create_platform)
    if not created then
        state.status = 'disabled: ' .. tostring(platform)
        return nil, state.status
    end

    -- The UI bridge, if the loader hands this addon its API factory. It is what the
    -- new architecture drives; without it the addon does not synthesise a drag at all,
    -- because a synthesised one cannot avoid pressing whatever the pointer crosses.
    local factory = environment.create_api or (loader and loader.create_api)
    state.bridge, state.bridge_reason = module.ui_bridge(factory)
    attach_native(state, platform)
    -- The ini is read once and kept as the base; the effective settings are the
    -- base at the current display scale, so a resolution change can be followed
    -- without re-reading anything.
    state.base_settings = read_settings()
    state.settings = state.base_settings
    state.status = state.settings.enabled and 'running' or 'disabled: config'

    local last_button = false
    local last_frame_ms, last_log_ms = -1, -100000
    -- thumb, jump and injected_total belonged to the removed wheel route and stay
    -- nil, nil and 0: begin_drag and the log still read them, so the drag record
    -- and the log keep their fields.
    local drag, thumb, jump = nil, nil, nil
    -- Input capture outlives a cancelled scroll until the physical mouse-up.
    -- Releasing over another control must not turn the old hold into a click.
    local settings_capture
    local injected_total = 0
    local trace, reason_counts = {}, {}
    local function note(reason)
        state.last_reason = reason
        state.dirty = true
        reason_counts[reason] = (reason_counts[reason] or 0) + 1
    end

    -- The log is the flight recorder: settings, counters, health, geometry,
    -- calibration, reason tally, trace. Rewritten, never grown.
    local function log(force)
        -- The clock is read only when the log may be written: frame() calls this
        -- every frame, and without diagnostics nothing is written.
        if not force and (state.settings.diagnostics ~= 1 or not state.dirty) then return end
        local now = platform.now()
        if not force and now - last_log_ms < state.settings.log_interval_ms then return end
        last_log_ms, state.dirty = now, false
        pcall(function() -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
            local file = loader.open_log and loader.open_log('ClickableScrollbars.log')
            if not file then return end
            local out = {}
            local function put(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
            put('%s', state.revision)
            put('status=%s', state.status)
            if state.last_error then put('error=%s', state.last_error) end
            put('--- settings')
            put('scale=%s', tostring(state.scale or 1))
            put('display_height=%s', tostring(state.display_height or 'unknown'))
            for _, key in ipairs({'enabled', 'center_tolerance', 'jump_max_notches', 'correction_notches',
                                  'max_corrections', 'settle_delay_ms', 'settle_interval_ms', 'settle_stable_px',
                                  'settle_checks', 'drag_threshold', 'drag_max_step_px', 'drag_max_notches',
                                  'calibration_samples', 'calibration_min_px', 'calibration_max_px',
                                  'cooldown_ms', 'min_capture_interval_ms', 'log_interval_ms', 'trace_lines',
                                  'trace_events', 'use_window_capture', 'error_limit', 'dump_captures',
                                  'strip_width', 'window', 'narrow_width',
                                  'narrow_window', 'min_height', 'min_width', 'max_width', 'min_luma', 'max_luma',
                                  'min_contrast', 'click_contrast', 'thumb_margin', 'column_tolerance',
                                  'bar_cache_ms', 'window_max', 'probe_step', 'burst_cache_ms',
                                  'burst_capture_every', 'capture_budget_ms_per_s', 'scale_geometry',
                                  'cursor_mask_radius', 'emit_max_notches',
                                  'capture_budget_floor_ms_per_s',
                                  'drag_column_margin',
                                  'drag_verify_notches', 'drag_verify_ms', 'drag_stall_confirmations',
                                  'native', 'native_verify_ms'}) do
                put('%s=%s', key, tostring(state.settings[key]))
            end
            put('--- counters')
            for _, key in ipairs({'clicks', 'pages', 'drags', 'corrections', 'no_response', 'misses', 'skipped',
                                  'capture_failures', 'errors', 'frames', 'down_frames', 'frame_clicks',
                                  'wheel_units', 'drag_notches', 'burst_skips', 'budget_skips',
                                  'emit_clamps', 'settle_budget_skips', 'drag_verifies', 'drag_stalls',
                                  'drag_limits', 'drag_out', 'drag_rejects', 'mask_retries', 'track_drops',
                                  'drag_foreground_pauses', 'settle_unfocused', 'drag_resyncs',
                                  'native_writes', 'native_ok', 'native_fallbacks'}) do
                put('%s=%d', key, state[key] or 0)
            end
            put('--- health')
            put('capture_source=%s', tostring(state.capture_source or 'window'))
            put('capture_fallbacks=%d', state.capture_fallbacks or 0)
            put('wide_retries=%d', state.wide_retries or 0)
            put('geometry_failures=%d', state.geometry_failures or 0)
            put('capture_ms_per_s=%d', state.capture_window_ms or 0)
            put('capture_share_pct=%.1f', (state.capture_window_ms or 0) / 10)
            put('budget_effective=%s', tostring(math.floor(state.effective_budget_ms_per_s
                or state.settings.capture_budget_ms_per_s)))
            put('game_fps=%s', state.frame_interval_ms and string.format('%.0f', 1000 / state.frame_interval_ms)
                or 'unknown')
            put('captures=%d', state.captures)
            put('capture_ms_max=%d', state.capture_ms_max)
            put('capture_ms_avg=%.3f', state.captures > 0 and state.capture_ms_total / state.captures or 0)
            put('frame_ms_max=%d', state.frame_ms_max)
            put('frame_ms_avg=%.4f', state.frames > 0 and state.frame_ms_total / state.frames or 0)
            put('--- state')
            put('drag_active=%s', tostring(state.drag_active or false))
            put('jump_active=%s', tostring(jump ~= nil))
            put('injected_since_observe=%d', injected_total - (thumb and thumb.injected_at or injected_total))
            put('last_reason=%s', tostring(state.last_reason))
            put('last_direction=%s', tostring(state.last_direction or 'none'))
            put('last_notches=%d', state.last_notches or 0)
            put('last_delta=%s', tostring(state.last_delta or 'none'))
            put('last_moved=%s', tostring(state.last_moved or 'none'))
            put('pixels_per_notch=%s', state.pixels_per_notch and string.format('%.2f', state.pixels_per_notch)
                or 'none')
            local samples = {}
            for index = 1, #state.calibration do samples[index] = string.format('%.2f', state.calibration[index]) end
            put('calibration=%s', #samples > 0 and table.concat(samples, ',') or 'none')
            local bar = state.last_bar
            put('last_bar=%s', bar and (bar.left .. ',' .. bar.top .. ',' .. bar.right .. ',' .. bar.bottom)
                or 'none')
            put('last_bar_masked=%s', tostring(state.last_thumb_masked or false))
            local cache = state.bar_cache
            put('bar_cache=%s', cache and (cache.left .. ',' .. cache.right) or 'none')
            local tracked = thumb
            put('thumb=%s', tracked and string.format('%d..%d centre=%.1f height=%s', tracked.left, tracked.right,
                tracked.center_y, tostring(tracked.height)) or 'none')
            put('track_top=%s', state.track_top and string.format('%.1f', state.track_top) or 'none')
            put('track_bottom=%s', state.track_bottom and string.format('%.1f', state.track_bottom) or 'none')
            put('drag_held=%s', drag and (drag.held_units == 1 and 'up' or (drag.held_units == -1 and 'down'
                or 'none')) or 'none')
            -- The measured interface ruler: the bar's thickness against its
            -- reference thickness on the machine the constants were measured on.
            put('ui_ruler=%s', state.ruler and string.format('%.3f', state.ruler) or 'none')
            put('ui_bridge=%s', state.bridge and string.format('ui=%s dispatch=%s', tostring(state.bridge.ui),
                tostring(state.bridge.dispatch)) or ('none (' .. tostring(state.bridge_reason) .. ')'))
            if state.native then
                local model = state.native_model
                put('native grid=%s state=%s', tostring(state.native.key or 'resolved'),
                    state.native_failed and 'retired' or 'active')
                put('native model value=%s scroll=%s span=%s content=%s viewport=%s'
                    .. ' first=%s last=%s anchor=%s items=%s rows=%s columns=%s',
                    model and string.format('%.4f', model.value) or 'none',
                    model and string.format('%.1f', model.scroll or -1) or 'none',
                    model and string.format('%.1f', model.span) or 'none',
                    model and string.format('%.1f', model.content) or 'none',
                    model and string.format('%.1f', model.viewport) or 'none',
                    tostring(model and model.first), tostring(model and model.last),
                    tostring(model and model.anchor),
                    tostring(model and model.items), tostring(model and model.rows),
                    tostring(model and model.columns))
                put('native last_value=%s track=%s', state.native_value and string.format('%.4f', state.native_value)
                    or 'none', tostring(state.native_state_reason or 'read'))
            else
                put('native none (%s)', tostring(state.native_reason))
            end
            put('last_luminance=%s', tostring(state.last_luminance or 'none'))
            put('last_click_luma=%s', state.last_click_luma and string.format('%.1f', state.last_click_luma)
                or 'none')
            put('last_bar_luma=%s', state.last_bar_luma and string.format('%.1f', state.last_bar_luma) or 'none')
            put('background_luma=%s', tostring(state.last_background or 'none'))
            put('last_dump=%s', tostring(state.last_dump or 'none'))
            local names = {}
            for name in pairs(reason_counts) do names[#names + 1] = name end
            table.sort(names)
            local summary = {}
            for _, name in ipairs(names) do
                summary[#summary + 1] = name .. '=' .. reason_counts[name]
            end
            put('reason_counts=%s', #summary > 0 and table.concat(summary, ',') or 'none')
            put('--- trace')
            put('trace_lines=%d', #trace)
            for _, line in ipairs(trace) do put('trace %s', line) end
            file:write(table.concat(out, '\n') .. '\n')
            file:close()
        end)
    end

    local function record(fmt, ...)
        if state.settings.diagnostics ~= 1 then return end
        local line = select('#', ...) > 0 and string.format(fmt, ...) or fmt
        trace[#trace + 1] = string.format('%d %s', math.floor(platform.now()), line)
        while #trace > state.settings.trace_lines do table.remove(trace, 1) end
        state.dirty = true
    end

    -- The budget is a share of frame time, not a capture count, with a floor so the
    -- feature never stops answering. Only the log reads it now (budget_effective).
    local function refresh_budget()
        local configured = state.settings.capture_budget_ms_per_s
        if configured <= 0 then
            state.effective_budget_ms_per_s = 0
            return
        end
        local interval = state.frame_interval_ms
        local budget = configured
        if interval and interval > 20 then
            budget = configured * (20 / interval)
        end
        budget = math.max(state.settings.capture_budget_floor_ms_per_s, budget)
        if budget > configured then budget = configured end
        state.effective_budget_ms_per_s = budget
    end

    -- Geometry follows the display height and is re-derived whenever it changes, so a
    -- monitor or resolution change is picked up on the next press.
    local function refresh_geometry(force) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
        -- A display query must never be able to stop the addon: a driver or
        -- Windows quirk here costs the scale, not the feature. The failure is
        -- counted and logged once per state change.
        local height = nil
        if platform.display_height then
            local ok, value = pcall(platform.display_height)
            if ok then
                height = value
                if state.geometry_failed then
                    state.geometry_failed = false
                    record('display query recovered after %d failures', state.geometry_failures or 0)
                end
            else
                state.geometry_failures = (state.geometry_failures or 0) + 1
                if not state.geometry_failed then
                    state.geometry_failed = true
                    record('display query failed: %s', tostring(value))
                end
            end
        end
        if not height then return false end
        local guess = state.settings.scale_geometry == 1 and module.scale_for_height(height) or 1
        -- The display height is only a guess: the bar's measured thickness corrects it
        -- within a factor of two, while the display it was measured on is unchanged.
        -- The measurement may correct the guess downwards, never upwards: a larger
        -- capture window sees more of the screen, and a false bar-like run of the
        -- wrong thickness must not be able to widen it.
        local ruler = state.ruler
        if ruler and state.ruler_height and math.abs(state.ruler_height - height) > 0.02 * height then
            ruler, state.ruler = nil, nil
        end
        local scale = ruler and math.min(guess, clamp(ruler, guess / 2, guess * 2)) or guess
        if not force and state.scale and math.abs(scale - state.scale) <= 0.02 * state.scale then return false end
        local first = state.scale == nil
        local moved_display = state.display_height ~= nil and math.abs(state.display_height - height) > 0.02 * height
        state.display_height, state.scale = height, scale
        state.settings = module.scale_settings(state.base_settings, scale)
        if not first then
            state.bar_cache, state.thumb_height, state.pixels_per_notch = nil, nil, nil
            state.calibration = {}
            if moved_display then state.ruler = nil end
            record('geometry changed scale=%.3f height=%d window=%d strip=%d mask=%d step=%.1f', scale, height,
                   state.settings.window, state.settings.strip_width, state.settings.cursor_mask_radius,
                   state.settings.default_pixels_per_notch)
            state.dirty = true
        end
        return true
    end

    -- The drag record; begin_native_drag adds the native fields. The anchor, column
    -- and wheel-step fields served the removed wheel route and keep the record's shape.
    local function begin_drag(cursor_x, cursor_y, now, left, right, side, unmeasured, track) -- lint-ok: R12 moved unchanged from the single file; existing debt, not new
        local centre = thumb and thumb.center_y or nil
        drag = {start_x = cursor_x, start_y = cursor_y, last_y = cursor_y, last_raw_y = cursor_y,
                unmeasured = unmeasured, active = false,
                fraction = 0, total = 0, verified_at = now, verified_units = injected_total,
                observed_centre = centre, observe_units = injected_total,
                anchor_y = cursor_y, anchor_centre = centre,
                column_left = left, column_right = right,
                track_top = track and track.top or nil,
                track_bottom = track and (track.top + track.length) or nil}
    end

    -- The native route's one gesture: while the button is held the list's own
    -- scroll value follows the pointer, so the thumb moves by the distance the
    -- pointer moved and nothing is injected anywhere. The first write of a
    -- gesture is checked against the game's read-back. A failed route is retired
    -- for that controller until a press resolves a different one.
    local function native_retire(reason)
        state.native_failed = true
        state.native_failed_key = state.native and state.native.key
        state.native_fallbacks = (state.native_fallbacks or 0) + 1
        note('native_retired')
        record('native retired (%s) after %d writes', tostring(reason), state.native_writes or 0)
    end

    -- The two tables a hold refreshes its model into, in turn: the press
    -- snapshot stays immutable, and state.native_model always holds the last
    -- model that passed.
    local live_models = {{}, {}}

    -- A controller can disappear or be reused for another category during a
    -- hold. Re-validate before writing; plausible stale memory is not proof
    -- that this is still the list the player grabbed. First the reads that
    -- resolved the owner are repeated: while their bytes are unchanged the
    -- resolution would find this owner again, and only a change resolves it
    -- afresh. Then the list's model is read again and must still be the
    -- grabbed list's.
    local function current_native(gesture)
        local api, bridge = state.native_api, state.native
        if not module.native_unchanged(api, bridge and bridge.tape) then
            bridge = module.native_resolve(api, state.native_memory)
            if not bridge or bridge.key ~= gesture.key then return nil end
        end
        local spare = state.native_model == live_models[1] and live_models[2] or live_models[1]
        local model = module.native_state(bridge, spare)
        local original = gesture.model
        if not model or model.items ~= original.items or model.kind ~= original.kind
            or math.abs(model.content - original.content) > 0.1
            or math.abs(model.span - original.span) > 0.1 then return nil end
        state.native, state.native_model = bridge, model
        return model
    end

    -- Moves the list to value. False when the write was refused: the route is
    -- retired and the gesture dropped.
    local function write_native(model, value)
        local written, reason = module.native_apply(state.native, model, value)
        if not written then
            native_retire(reason or 'write refused')
            drag, thumb, state.drag_active = nil, nil, false
            return false
        end
        if not drag.sent then state.drags = state.drags + 1 end
        state.drag_active = true
        state.native_writes = (state.native_writes or 0) + 1
        drag.sent, drag.writes = written, drag.writes + 1
        state.native_value = written
        return true
    end

    -- Verification also runs when the pointer stops. Small scrolls may leave
    -- the visible row indices unchanged: verify the rendered thumb in that
    -- case, instead of switching actuators halfway through a valid drag.
    -- Native geometry includes the rendered thumb: a rejected write never
    -- invokes screen capture to verify the same gesture.
    local function verify_native(now)
        if not drag.sent or drag.checked or now - drag.started < state.settings.native_verify_ms then return end
        local after = module.native_state(state.native)
        local moved = after and module.native_moved(drag.model, after)
        if not moved and math.abs(drag.sent - drag.model.value) * drag.track.span < 3 then return end
        drag.checked = true
        if moved then
            state.native_ok = (state.native_ok or 0) + 1
            note('native_drag')
        else
            native_retire('the game did not answer the write')
            drag, thumb, state.drag_active = nil, nil, false
        end
    end

    local function service_native_drag(now, cursor_y)
        local model = current_native(drag)
        if not model then
            drag, thumb, state.drag_active = nil, nil, false
            note('native_cancelled')
            return
        end
        -- The press snapshot is immutable for the entire gesture. Read-back
        -- refreshes the live model, never the origin of the pointer delta.
        local value = module.native_value_at_grab(drag.model, drag.track, drag.press_y, cursor_y)
        if not value then return end
        if math.abs(value - (drag.sent or drag.model.value)) > 0.000001 and not write_native(model, value) then
            return
        end
        verify_native(now)
    end

    -- A press on the bar arms the native gesture: the list's value follows the
    -- pointer for as long as the button is held, with no capture and no input.
    -- Failure cancels this hold instead of switching input routes mid-gesture.
    local function begin_native_drag(cursor_x, cursor_y, now, thumb_centre, thumb_height, left, right, side, native_track) -- lint-ok: R12 moved unchanged from the single file; existing debt, not new
        local model = state.native_model
        if not model or not thumb_centre or not thumb_height then return false end
        local track = native_track or module.native_track(model, thumb_centre - thumb_height / 2, thumb_height)
        if not track then return false end
        if state.native.route == 'settings' then
            if not module.native_settings_input(state.native) then
                note('settings_input_unavailable')
                return false
            end
            settings_capture = state.native
        end
        begin_drag(cursor_x, cursor_y, now, left, right, side, nil, track)
        drag.native, drag.track, drag.press_y = true, track, cursor_y
        drag.model, drag.key = model, state.native.key
        drag.started, drag.writes, drag.checked = now, 0, false
        record('native press y=%d track=%.1f..%.1f thumb=%.1f value=%.4f', cursor_y, track.top,
               track.top + track.length, track.thumb, model.value)
        return true
    end

    -- The grid is registered only while its Armory or loadout screen exists,
    -- and its controller is rebuilt with the screen, so resolution is attempted when
    -- it is needed, cached, and dropped the moment a read stops passing its
    -- bounds. A stale pointer therefore costs one failed read, never a write.
    local function refresh_native(now)
        -- Measurement is kept even after a write was refused: the grid's own
        -- geometry (content, span, value) locates the track independently of
        -- whether a later write is honoured.
        if not state.native_api then
            if state.native_api_attempted then return nil end
            state.native_api_attempted = true
            local ok, api, reason = pcall(module.native_api)
            if not ok or type(api) ~= 'table' then
                state.native_reason = tostring(reason or api)
                return nil
            end
            state.native_api = api
        end
        -- Each screen rebuilds its controller - and with it the grid - every time
        -- it is entered, so the grid is resolved from dispatch afresh
        -- on each press. A remembered pointer reads plausibly long after its screen
        -- is gone and writes into nothing, which is exactly the failure this
        -- replaces.
        -- One memory view serves every resolution of the session.
        state.native_memory = state.native_memory or module.native_memory(state.native_api)
        local bridge, reason = module.native_resolve(state.native_api, state.native_memory)
        state.native_reason = reason
        if not bridge then
            state.native, state.native_model = nil, nil
            return nil
        end
        if state.native_failed_key and state.native_failed_key ~= bridge.key then
            -- A different screen: an earlier refusal belongs to that one.
            state.native_failed, state.native_failures = nil, 0
        end
        local model, state_reason = module.native_state(bridge)
        state.native_state_reason = state_reason
        state.native = bridge
        if not model then
            state.native_model = nil
            return nil
        end
        state.native_model = model
        return state.native
    end

    local function handle_press(now)
        state.clicks = state.clicks + 1
        -- frame() asked for the focus before calling this.
        if not state.settings.enabled or state.settings.native ~= 1 then return end
        -- An absent/unsupported/hidden owner is a definitive no-op. Never scan
        -- gameplay pixels looking for a possible scrollbar on an ordinary click.
        local native = refresh_native(now)
        if not native then return end
        local native_track = platform.viewport
            and module.native_screen_track(state.native_model, platform.viewport())
        if not native_track then return end
        local cursor_x, cursor_y = platform.cursor()
        if not cursor_x then return end
        if cursor_x < native_track.left - 3 or cursor_x > native_track.right + 3
            or cursor_y < native_track.top or cursor_y > native_track.top + native_track.length then
            return
        end
        if state.native_failed then return end
        local model = state.native_model
        local top = native_track.top + model.value * native_track.span
        local centre = top + native_track.thumb / 2
        if not begin_native_drag(cursor_x, cursor_y, now, centre, native_track.thumb,
                                 native_track.left, native_track.right, nil, native_track) then return end
        if cursor_y < top or cursor_y > top + native_track.thumb then
            drag.press_y = centre
            service_native_drag(now, cursor_y)
            state.pages = state.pages + 1
            note('native_jump')
        else
            note('bar_press')
        end
    end

    -- --------------------------------------------------------- frame steps
    -- frame() runs once per game update and calls the steps below. They share
    -- the gesture through install's locals (drag, settings_capture) and `state`,
    -- and create no table or closure per frame.

    -- The engine refreshes selection state each frame. Consume it before
    -- native row/tab handlers run, even if scrolling was cancelled. Resolve
    -- only the input singleton here; a previous menu owner may be gone.
    local function hold_settings_input(down)
        if platform.foreground_self() and not module.native_settings_input(settings_capture) then
            drag, state.drag_active = nil, false
            note('settings_input_cancelled')
        end
        if not down then settings_capture = nil end
    end

    -- record formats the value itself, and only while diagnostics keep the trace,
    -- so a release allocates nothing (it formatted a string on every release).
    local function release_drag()
        if drag.native then
            note('native_release')
            if drag.sent then
                record('native release writes=%d value=%.4f', drag.writes or 0, drag.sent)
            else
                record('native release writes=%d value=none', drag.writes or 0)
            end
        end
        drag, state.drag_active = nil, false
    end

    -- The held gesture, then a new press. While the button is held the list's own
    -- scroll value follows the pointer (service_native_drag). started is the
    -- frame's clock when diagnostics read it, else false.
    local function track_gesture(started, down, pressed)
        -- Focus loss cancels ownership; resuming an old drag after alt-tab can
        -- use a different menu or deliver queued input to another application.
        -- A press is refused here too, before handle_press counts it.
        if not platform.foreground_self() then
            drag, state.drag_active = nil, false
            return
        end
        -- Only a held button moves the drag or presses; a release needs no clock.
        local now = down and (started or platform.now())
        if drag then
            if not down then
                release_drag()
            elseif drag.native then
                local cursor_x, cursor_y = platform.cursor()
                if state.native_failed then
                    -- The game did not answer: drop the gesture; a later press on
                    -- another controller may try again.
                    drag, state.drag_active = nil, false
                    note('native_dropped')
                elseif cursor_x then
                    service_native_drag(now, cursor_y)
                end
            end
        end
        if pressed then
            state.frame_clicks = state.frame_clicks + 1
            handle_press(now)
        end
    end

    -- The game's own frame interval, reported in the log with the capture budget
    -- sized from it: a machine already struggling to hold frames gets a smaller share.
    -- GetTickCount64 advances in steps of about 15.6 ms, so above ~64 FPS several
    -- frames share one value: the interval is a clock step over the frames it held.
    local frames_in_tick = 0
    local function measure_interval(now)
        frames_in_tick = frames_in_tick + 1
        if now == last_frame_ms then return end
        if last_frame_ms > 0 then
            local interval = clamp((now - last_frame_ms) / frames_in_tick, 1, 1000)
            state.frame_interval_ms = state.frame_interval_ms and (state.frame_interval_ms * 0.9 + interval * 0.1)
                or interval
            refresh_budget()
        end
        last_frame_ms, frames_in_tick = now, 0
    end

    -- The log's frame time, with diagnostics only.
    local function measure_frame_time(started)
        local elapsed = platform.now() - started
        state.frame_ms_total = state.frame_ms_total + elapsed
        if elapsed > state.frame_ms_max then state.frame_ms_max = elapsed end
    end

    -- Runs once per game update (the guard's step; render never calls it). Every
    -- update is a frame: v2.1 also ran it from render and skipped a frame whose
    -- clock equalled the last one, which above ~64 FPS dropped whole updates.
    local function frame()
        -- The clock serves only the log's frame interval and frame time, so it is
        -- read on an idle frame only while diagnostics are on.
        local diagnostics = state.settings.diagnostics == 1
        local started = diagnostics and platform.now()
        if started then measure_interval(started) end
        state.frames = state.frames + 1
        state.last_key = diagnostics and platform.key_state and platform.key_state() or 0
        local down = platform.pressed()
        local was_down, pressed = last_button, false
        if down then
            state.down_frames = state.down_frames + 1
            pressed = not was_down
        end
        last_button = down
        if settings_capture then hold_settings_input(down) end
        if not state.settings.enabled then
            drag, state.drag_active = nil, false
        -- The gesture step runs only with a gesture or a press: on any other frame
        -- none of its branches applies, so the focus is not asked either.
        elseif drag or pressed then
            track_gesture(started, down, pressed)
        end
        if started then measure_frame_time(started) end
        log(false)
    end

    -- The JIT never compiles frame(): every trace through it aborts in log(), which
    -- creates a closure (this LuaJIT compiles neither FNEW nor UCLO). Its steps stay
    -- in the interpreter with it, so they add no trace to the shared code cache;
    -- so do the press and held-drag steps, like the native layer they drive.
    keep_interpreted({frame, hold_settings_input, track_gesture, release_drag, handle_press, refresh_native,
                      begin_native_drag, begin_drag, service_native_drag, current_native, write_native,
                      verify_native, native_retire, measure_interval, measure_frame_time})

    -- The update chain is runtime.guard's (Bingus Shared Runtime): error_limit
    -- own errors in a burst (ERROR_BURST_FRAMES clean frames end it) or as many
    -- failed updates below stop the addon; an update below that raised pauses it
    -- (the gesture and the settings capture are dropped) until 60 clean frames.
    -- A failing frame drops its half-finished interaction and is counted in
    -- state; the log is written at a burst's first error and when the addon
    -- stops; the stop reason survives shutdown.
    local frame_error, clean_frames = false, 0
    local guard

    local function step()
        frame_error = false
        local ok, reason = pcall(frame)
        if ok then return end
        frame_error = true
        local text = tostring(reason)
        state.errors = state.errors + 1
        state.last_error = text
        drag, state.drag_active = nil, false
        note('frame_error')
        record('error update #%d: %s', state.errors, text)
        error(text, 0)
    end

    -- After the update below: the burst count the log reports.
    local function after()
        if frame_error then clean_frames = 0 else clean_frames = clean_frames + 1 end
        state.burst_errors = clean_frames >= ERROR_BURST_FRAMES and 0 or guard.status.errors
    end

    local function pause()
        drag, state.drag_active, settings_capture = nil, false, nil
    end

    local function stop(reason)
        settings_capture = nil
        if reason == 'shutdown' then
            state.status = 'stopped'
            record('shutdown frames=%d clicks=%d pages=%d', state.frames or 0, state.clicks or 0, state.pages or 0)
            log(true)
            pcall(platform.close)
            return
        end
        state.status = reason
        log(true)
    end

    guard = runtime.guard({name = 'ClickableScrollbars', step = step, after = after, stop = stop, pause = pause,
                           errors = state.settings.error_limit, clean = ERROR_BURST_FRAMES, env = environment,
                           log = function(line)
                               record('%s', line)
                               if line:find(' error: ', 1, true) then log(true) end
                           end}).install()
    state.guard = guard.status

    -- Only update owns input processing. Running it again from render can
    -- double the native reads and log work within a single displayed frame.
    refresh_geometry(true)
    state.status = state.settings.enabled and 'running' or 'disabled: config'
    log(true)
    return state
end
