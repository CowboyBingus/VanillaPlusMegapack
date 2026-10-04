-- The defaults, the optional ini and the scale that follows the display.
local module, cs = ...
local clamp = cs.clamp

-- --------------------------------------------------------------- settings

-- Pixel constants are quoted for a 1440 px tall viewport and scaled to the interface;
-- ini values stay absolute and the bar's measured thickness overrides the estimate.
local DEFAULTS = {
    enabled = true,
    -- Capture geometry.
    strip_width = 96,        -- px captured horizontally, centred on the cursor
    window = 460,            -- px captured vertically either side of the cursor
    window_max = 1400,       -- widest the strip may grow to when a thumb does not fit
    narrow_width = 40,       -- px wide second pass once a bar column is known
    narrow_window = 420,     -- px tall second pass
    bar_cache_ms = 60000,    -- how long a known bar column is trusted
    -- Thumb classification.
    min_height = 44,         -- shortest accepted thumb, px
    max_height_ratio = 0.94, -- longest accepted thumb, fraction of the capture
    min_width = 6,           -- narrowest accepted thumb, px
    max_width = 28,          -- widest accepted thumb, px
    min_luma = 105,          -- thumb brightness window
    max_luma = 220,
    min_luma_floor = 40,     -- absolute floor once the threshold is adapted
    min_contrast = 30,       -- thumb must be this much brighter than the strip's dark quartile
    local_contrast = true,   -- and brighter than the pixels beside it (rejects wide bright areas)
    local_offset = 16,       -- px to either side used for that comparison
    max_spread = 18,         -- max channel spread for "neutral grey"
    min_fill = 0.72,         -- fraction of grey pixels required inside a run
    max_bridge = 160,        -- masked rows a run may bridge (cursor overlay)
    max_gap = 6,             -- unmasked rows a run may bridge (small bright overlay)
    max_variance = 14,       -- max deviation from the thumb's median brightness
    min_uniformity = 0.85,   -- fraction of samples that must stay within it
    edge_contrast = 25,      -- background beside the thumb must be this much darker
    -- Click interpretation.
    thumb_margin = 9,        -- px around the thumb treated as the thumb
    column_tolerance = 12,   -- px the cursor may sit outside the thumb column
    click_contrast = 25,     -- click pixel must be this much darker than the bar
    -- Measured bounding box of the pointer's sprite: inside it, coloured or over-bright
    -- rows are bridged so the thumb stays whole under the pointer.
    cursor_mask = {x0 = -72, x1 = 72, y0 = -72, y1 = 72},
    -- Which keys follow the display scale rather than staying absolute.
    scaled_keys = {'strip_width', 'window', 'narrow_width', 'narrow_window', 'min_height', 'min_width',
                   'max_width', 'local_offset', 'max_bridge', 'max_gap', 'thumb_margin',
                   'column_tolerance', 'drag_threshold', 'drag_max_step_px',
                   'probe_step',
                   'calibration_min_px', 'calibration_max_px',
                   'center_tolerance', 'settle_stable_px'},
    cursor_mask_radius = 72, -- px, scaled with the display
    -- Aiming and following. The seed is the step measured live on the Armory list:
    -- 12.998 px of thumb travel per notch over 14 notches at the reference scale.
    default_pixels_per_notch = 13, -- measured wheel step before calibration
    bar_reference_width = 10,      -- the bar's thickness at that reference scale
    center_tolerance = 4,    -- px of aimed error that counts as centred
    jump_max_notches = 120,  -- notches one track-click jump may send
    emit_max_notches = 16,   -- notches one frame may inject; the rest follows next frame
    correction_notches = 40, -- notches one settle correction may add
    max_corrections = 2,     -- settle corrections per jump, each of which must shrink the error
    settle_delay_ms = 200,   -- wait after a jump before measuring the thumb
    settle_interval_ms = 60, -- between settle measurements
    settle_stable_px = 2,    -- movement below this counts as stopped
    settle_checks = 8,       -- measurements before a jump is given up
    drag_threshold = 10,     -- px of vertical movement that starts a drag
    drag_max_step_px = 220,  -- a larger single-frame jump is a pointer teleport
    drag_max_notches = 40,   -- hard cap on the notches one drag frame may send
    -- Accepted for older INIs; wheel input now stays inside the exact column.
    drag_column_margin = 2.8,
    drag_verify_notches = 3, -- notches before a drag re-checks the thumb
    -- Gap between drag re-checks: each costs ~1.9 ms measured, and every check skipped
    -- is another stretch of notches spent past a thumb the game has clamped.
    drag_verify_ms = 45,
    drag_stall_confirmations = 2, -- readings in a row that must show no thumb movement
    track_clamp_max_notches = 12,  -- notches a learned track end may block before it is dropped
    -- Drive the value and run the layout solver together. The old bare value
    -- write could move only the thumb; the solver also updates the visible rows.
    native = 1,
    native_verify_ms = 200,
    calibration_samples = 7, -- observed steps kept for the median
    calibration_min_px = 4,  -- accepted observed px/notch window
    calibration_max_px = 60,
    -- Diagnostics.
    trace_lines = 48,        -- decisions kept for the log
    trace_events = 0,        -- 1 records every emission and drag step
    diagnostics = 0,         -- opt-in interaction traces and periodic disk writes
    log_interval_ms = 5000,  -- shortest gap between log writes
    cooldown_ms = 0,         -- shortest gap between two track-click jumps
    min_capture_interval_ms = 40,
    use_window_capture = 1,  -- 1 tries the game's own window DC before the desktop DC
    scale_geometry = 1,      -- 1 scales the pixel geometry to the display height
    probe_step = 8,             -- rows between column probes (a run is far taller)
    -- Captures are the only expensive work here; a press on a bar that was already
    -- measured is answered from that analysis and the notches sent since.
    burst_cache_ms = 250,       -- how long a recent analysis may classify a press
    burst_capture_every = 3,    -- force a real capture after this many skips
    capture_budget_ms_per_s = 60, -- capture time the addon may spend per second
    capture_budget_floor_ms_per_s = 30, -- floor for that budget when frames are slow
    error_limit = 8,         -- frame errors in one burst that stop the addon
    dump_captures = 0,       -- diagnostic BMP dumps; 0 keeps nothing on disk
}

function module.parse_settings(text, base) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    local settings = {}
    for key, value in pairs(base or DEFAULTS) do settings[key] = value end
    -- Keys that came from the ini hold absolute device pixels and are never
    -- scaled: a value the user typed means exactly what it says.
    local overridden = {}
    if type(text) == 'string' then
        for line in text:gmatch('[^\r\n]+') do
            local key, value = line:match('^%s*([%a_]+)%s*=%s*([%-%d%.]+)%s*$')
            if key and DEFAULTS[key] ~= nil and type(DEFAULTS[key]) ~= 'table' then
                local number = tonumber(value)
                if number then
                    overridden[key] = true
                    if type(DEFAULTS[key]) == 'boolean' then
                        settings[key] = number ~= 0
                    else
                        settings[key] = number
                    end
                end
            end
        end
    end
    settings.overridden = overridden
    return module.clamp_settings(settings)
end

-- Bounds every value so a hostile or careless ini cannot produce a geometry the
-- detector or the capture surface cannot honour.
function module.clamp_settings(settings)
    settings.strip_width = clamp(math.floor(settings.strip_width), 32, 240)
    settings.window = clamp(math.floor(settings.window), 120, 1400)
    settings.window_max = clamp(math.floor(settings.window_max), settings.window, 1400)
    settings.narrow_width = clamp(math.floor(settings.narrow_width), 16, 120)
    settings.narrow_window = clamp(math.floor(settings.narrow_window), 120, 1400)
    settings.bar_cache_ms = clamp(math.floor(settings.bar_cache_ms), 0, 600000)
    settings.min_height = clamp(math.floor(settings.min_height), 12, 1200)
    settings.max_height_ratio = clamp(settings.max_height_ratio, 0.1, 1)
    settings.min_width = clamp(math.floor(settings.min_width), 3, 60)
    settings.max_width = clamp(math.floor(settings.max_width), settings.min_width, 80)
    settings.min_luma = clamp(math.floor(settings.min_luma), 30, 250)
    settings.max_luma = clamp(math.floor(settings.max_luma), settings.min_luma + 5, 255)
    settings.min_luma_floor = clamp(math.floor(settings.min_luma_floor), 10, 240)
    settings.min_contrast = clamp(math.floor(settings.min_contrast), 5, 200)
    settings.local_contrast = settings.local_contrast and true or false
    settings.local_offset = clamp(math.floor(settings.local_offset), 4, 200)
    settings.max_spread = clamp(math.floor(settings.max_spread), 2, 120)
    settings.min_fill = clamp(settings.min_fill, 0.2, 1)
    settings.max_bridge = clamp(math.floor(settings.max_bridge), 0, 400)
    settings.max_gap = clamp(math.floor(settings.max_gap), 0, 400)
    settings.max_variance = clamp(math.floor(settings.max_variance), 1, 120)
    settings.min_uniformity = clamp(settings.min_uniformity, 0.1, 1)
    settings.edge_contrast = clamp(math.floor(settings.edge_contrast), 0, 200)
    settings.thumb_margin = clamp(math.floor(settings.thumb_margin), 0, 200)
    settings.column_tolerance = clamp(math.floor(settings.column_tolerance), 0, 120)
    settings.click_contrast = clamp(math.floor(settings.click_contrast), 0, 200)
    settings.default_pixels_per_notch = clamp(settings.default_pixels_per_notch, 4, 400)
    settings.bar_reference_width = clamp(settings.bar_reference_width, 2, 60)
    settings.center_tolerance = clamp(math.floor(settings.center_tolerance), 0, 100)
    settings.jump_max_notches = clamp(math.floor(settings.jump_max_notches), 1, 2000)
    settings.emit_max_notches = clamp(math.floor(settings.emit_max_notches), 1, 2000)
    settings.correction_notches = clamp(math.floor(settings.correction_notches), 1, 200)
    settings.max_corrections = clamp(math.floor(settings.max_corrections), 0, 30)
    settings.settle_delay_ms = clamp(math.floor(settings.settle_delay_ms), 20, 5000)
    settings.settle_interval_ms = clamp(math.floor(settings.settle_interval_ms), 10, 2000)
    settings.settle_stable_px = clamp(settings.settle_stable_px, 0, 100)
    settings.settle_checks = clamp(math.floor(settings.settle_checks), 1, 50)
    settings.drag_threshold = clamp(math.floor(settings.drag_threshold), 2, 200)
    settings.drag_max_step_px = clamp(math.floor(settings.drag_max_step_px), 20, 2000)
    settings.drag_max_notches = clamp(math.floor(settings.drag_max_notches), 1, 400)
    settings.drag_column_margin = clamp(settings.drag_column_margin, 0.5, 40)
    settings.drag_verify_notches = clamp(math.floor(settings.drag_verify_notches), 1, 100)
    settings.drag_verify_ms = clamp(math.floor(settings.drag_verify_ms), 20, 5000)
    settings.drag_stall_confirmations = clamp(math.floor(settings.drag_stall_confirmations), 1, 10)
    settings.track_clamp_max_notches = clamp(math.floor(settings.track_clamp_max_notches), 0, 400)
    settings.native = clamp(math.floor(settings.native), 0, 1)
    settings.native_verify_ms = clamp(math.floor(settings.native_verify_ms), 20, 2000)
    settings.calibration_samples = clamp(math.floor(settings.calibration_samples), 1, 25)
    settings.calibration_min_px = clamp(settings.calibration_min_px, 1, 200)
    settings.calibration_max_px = clamp(settings.calibration_max_px, settings.calibration_min_px, 400)
    settings.trace_lines = clamp(math.floor(settings.trace_lines), 0, 500)
    settings.trace_events = clamp(math.floor(settings.trace_events), 0, 1)
    settings.log_interval_ms = clamp(math.floor(settings.log_interval_ms), 0, 60000)
    settings.cooldown_ms = clamp(math.floor(settings.cooldown_ms), 0, 5000)
    settings.min_capture_interval_ms = clamp(math.floor(settings.min_capture_interval_ms), 0, 5000)
    settings.use_window_capture = clamp(math.floor(settings.use_window_capture), 0, 1)
    settings.scale_geometry = clamp(math.floor(settings.scale_geometry), 0, 1)
    settings.probe_step = clamp(math.floor(settings.probe_step), 1, 64)
    settings.burst_cache_ms = clamp(math.floor(settings.burst_cache_ms), 0, 2000)
    settings.burst_capture_every = clamp(math.floor(settings.burst_capture_every), 1, 100)
    settings.capture_budget_ms_per_s = clamp(math.floor(settings.capture_budget_ms_per_s), 0, 5000)
    settings.capture_budget_floor_ms_per_s = clamp(math.floor(settings.capture_budget_floor_ms_per_s), 0, 5000)
    settings.error_limit = clamp(math.floor(settings.error_limit), 1, 1000)
    settings.dump_captures = clamp(math.floor(settings.dump_captures), 0, 50)
    settings.cursor_mask_radius = clamp(settings.cursor_mask_radius, 24, 320)
    settings.cursor_mask = {
        x0 = -math.floor(settings.cursor_mask_radius), x1 = math.ceil(settings.cursor_mask_radius),
        y0 = -math.floor(settings.cursor_mask_radius), y1 = math.ceil(settings.cursor_mask_radius),
    }
    settings.enabled = settings.enabled and true or false
    return settings
end

-- The reference geometry was measured on a 1440 px tall viewport, which the
-- interface was assumed to follow; the bar's measured thickness corrects that.
local REFERENCE_HEIGHT = 1440

function module.scale_for_height(height)
    if type(height) ~= 'number' or height < 240 then return 1 end
    return clamp(height / REFERENCE_HEIGHT, 0.4, 4)
end

function module.scale_settings(base, scale)
    local scaled = {}
    for key, value in pairs(base) do scaled[key] = value end
    scaled.scale = scale
    if scale == 1 then return module.clamp_settings(scaled) end
    for _, key in ipairs(DEFAULTS.scaled_keys) do
        if not (base.overridden and base.overridden[key]) then
            scaled[key] = base[key] * scale
        end
    end
    if not (base.overridden and base.overridden.cursor_mask_radius) then
        scaled.cursor_mask_radius = base.cursor_mask_radius * scale
    end
    return module.clamp_settings(scaled)
end

-- For the runtime.
cs.DEFAULTS = DEFAULTS
