-- Detector tests on synthetic frames, plus settings parsing and scaling.

package.path = (arg and arg[1] or '.') .. '/?.lua;' .. package.path

rawset(_G, '__CLICKABLE_SCROLLBARS_TEST', true)
local module = assert(loadfile((arg and arg[2]) or 'ClickableScrollbars/src/clickable_scrollbars.lua'))()
-- The legacy pixel detector is not shipped in the entry: load it from src/ beside the module.
local function load_detector(target, environment)
    local file = assert(io.open(((arg and arg[1]) or '.') .. '/src/detector.lua', 'rb'))
    local chunk = assert(loadstring(file:read('*a'), '@detector.lua'))
    file:close()
    if environment then setfenv(chunk, environment) end
    chunk(target, {clamp = function(value, low, high)
        if value < low then return low end
        if value > high then return high end
        return value
    end})
end
load_detector(module)

local passed, failed = 0, 0
local function check(name, condition, detail)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL ' .. name .. (detail and (' - ' .. tostring(detail)) or ''))
    end
end

local function sample(width, height, background, patches, origin_x, origin_y)
    patches = patches or {}
    -- Patches paint in order, so a later patch covers an earlier one: a small
    -- overlay on a bar has to be able to override the bar's own fill.
    local function rgb(x, y)
        local r, g, b = background[1], background[2], background[3]
        for index = 1, #patches do
            local patch = patches[index]
            if x >= patch[1] and x <= patch[2] and y >= patch[3] and y <= patch[4] then
                r, g, b = patch[5], patch[6], patch[7]
            end
        end
        return r, g, b
    end
    return {width = width, height = height, origin_x = origin_x or 0, origin_y = origin_y or 0, rgb = rgb}
end

local options = module.parse_settings(nil, nil)

-- 1. A uniform grey bar on dark panel background is recognised.
local bar = sample(80, 400, {45, 45, 45}, {{30, 41, 60, 300, 149, 149, 149}})
local found, reason = module.find_thumb(bar, {x = 36, y = 380}, options)
check('solid bar found', found ~= nil, reason)
check('solid bar bounds', found and found.left == 30 and found.right == 41
    and found.top == 60 and found.bottom == 300,
    found and (found.left .. ',' .. found.top .. ',' .. found.right .. ',' .. found.bottom))

-- 2. Click above, below and on the thumb.
local above = module.decide(found, {x = 36, y = 40}, bar, options)
check('click above the thumb is a track press', above == 'track', above)
local below = module.decide(found, {x = 36, y = 360}, bar, options)
check('click below the thumb is a track press', below == 'track', below)
local on_thumb = module.decide(found, {x = 36, y = 200}, bar, options)
check('click on the thumb is a thumb press', on_thumb == 'thumb', on_thumb)

-- 3. Thin dividers and hairline borders are not thumbs.
local hairline = sample(80, 400, {45, 45, 45}, {{30, 31, 20, 380, 170, 170, 170}})
check('hairline rejected', module.find_thumb(hairline, {x = 30, y = 40}, options) == nil)

-- 4. Bright content is above the accepted brightness window.
local bright = sample(80, 400, {45, 45, 45}, {{30, 41, 40, 340, 250, 250, 250}})
check('bright band rejected', module.find_thumb(bright, {x = 36, y = 60}, options) == nil)

-- 5. A grey band that fades has no uniform body.
local faded = {
    width = 80, height = 400, origin_x = 0, origin_y = 0,
    rgb = function(x, y)
        if x >= 30 and x <= 41 and y >= 40 and y <= 340 then
            local value = 110 + math.floor((y - 40) * 0.3)
            return value, value, value
        end
        return 45, 45, 45
    end,
}
check('faded band rejected', module.find_thumb(faded, {x = 36, y = 20}, options) == nil)

-- 6. A short grey tab is below the minimum height.
local short = sample(80, 400, {45, 45, 45}, {{30, 41, 100, 130, 149, 149, 149}})
check('short bar rejected', module.find_thumb(short, {x = 36, y = 60}, options) == nil)

-- 7. The cursor overlay may split the thumb; the masked rows are bridged.
local bridged = sample(80, 400, {45, 45, 45},
    {{30, 41, 60, 220, 149, 149, 149}, {30, 41, 150, 165, 255, 255, 255}})
local bridged_found = module.find_thumb(bridged, {x = 36, y = 145}, options)
check('cursor overlay bridged', bridged_found ~= nil
    and bridged_found.top <= 70 and bridged_found.bottom >= 210,
    bridged_found and (bridged_found.top .. '..' .. bridged_found.bottom))

-- 8. Clicking bright content in the track column is not treated as a track click.
local content = sample(80, 400, {45, 45, 45},
    {{30, 41, 60, 300, 149, 149, 149}, {20, 45, 340, 360, 235, 235, 235}})
local content_found = module.find_thumb(content, {x = 36, y = 350}, options)
local content_direction, content_reason = module.decide(content_found, {x = 36, y = 350}, content, options)
check('bright track click ignored', content_direction == nil and content_reason == 'click_not_on_track',
    content_reason)

-- 9. The bar nearest the cursor wins when the strip holds several candidates.
local two = sample(120, 400, {45, 45, 45},
    {{10, 21, 60, 300, 149, 149, 149}, {90, 101, 60, 300, 149, 149, 149}})
local two_found = module.find_thumb(two, {x = 96, y = 80}, options)
check('nearest bar chosen', two_found and two_found.left == 90,
    two_found and two_found.left)

-- 10. A coloured strip is not a neutral grey thumb.
local coloured = sample(80, 400, {45, 45, 45}, {{30, 41, 60, 300, 150, 90, 60}})
check('coloured band rejected', module.find_thumb(coloured, {x = 36, y = 20}, options) == nil)

-- 11. Analysis returns screen-independent action data.
local action = module.analyse(bar, {x = 36, y = 360}, options)
check('analyse returns a track press', action and action.hit == 'track' and action.bar.left == 30,
    action and action.hit)

-- 12. Settings parsing clamps hostile values and keeps the rest.
local settings = module.parse_settings('jump_max_notches=9999\nwindow=2\nmin_luma=0\nunknown=5\nenabled=0\n', nil)
check('settings clamped', settings.jump_max_notches == 2000 and settings.window == 120
    and settings.min_luma == 30 and settings.enabled == false,
    settings.jump_max_notches .. ',' .. settings.window)
check('unknown settings ignored', settings.unknown == nil)
check('removed settings are gone', settings.jump_pass_notches == nil and settings.emit_burst == nil
    and settings.queue_max == nil)
check('new settings clamped', module.parse_settings('correction_notches=9999\ncalibration_samples=99\n'
    .. 'drag_max_step_px=1\nerror_limit=0\n', nil).correction_notches == 200
    and module.parse_settings('correction_notches=9999\ncalibration_samples=99\n'
    .. 'drag_max_step_px=1\nerror_limit=0\n', nil).calibration_samples == 25
    and module.parse_settings('drag_max_step_px=1\n', nil).drag_max_step_px == 20
    and module.parse_settings('error_limit=0\n', nil).error_limit == 1)

-- 13. The band selector re-finds a thumb after the list has scrolled.
local moved = sample(80, 400, {45, 45, 45}, {{30, 41, 20, 260, 149, 149, 149}})
local band_found = module.find_thumb(moved, nil, options, {left = 28, right = 43})
check('band selection', band_found and band_found.top == 20, band_found and band_found.top)

-- 14. A short bright interruption inside an otherwise solid thumb is bridged.
local interrupted = sample(80, 400, {45, 45, 45},
    {{30, 41, 60, 300, 149, 149, 149}, {30, 41, 180, 184, 235, 235, 235}})
local interrupted_found = module.find_thumb(interrupted, {x = 36, y = 380}, options)
check('small interruption bridged', interrupted_found and interrupted_found.top == 60
    and interrupted_found.bottom == 300,
    interrupted_found and (interrupted_found.top .. '..' .. interrupted_found.bottom))

-- 15. Yellow end caps (measured on the Armory grid bar) do not hide the body.
local capped = sample(80, 400, {45, 45, 45},
    {{30, 41, 96, 104, 236, 226, 120}, {30, 41, 105, 295, 149, 149, 149},
     {30, 41, 296, 304, 236, 226, 120}})
local capped_found = module.find_thumb(capped, {x = 36, y = 20}, options)
check('yellow end caps tolerated', capped_found and capped_found.top <= 110
    and capped_found.bottom >= 290,
    capped_found and (capped_found.top .. '..' .. capped_found.bottom))

-- 16. A black capture is reported as such instead of looking like an empty menu.
local black = sample(40, 40, {0, 0, 0}, {})
check('black capture detected', module.strip_luminance(black) == 0, module.strip_luminance(black))
local lit = sample(40, 40, {45, 45, 45}, {})
check('lit capture measured', math.abs(module.strip_luminance(lit) - 45) < 0.001,
    module.strip_luminance(lit))

-- 17. A dim capture (GDI copy of a bright frame) still detects its thumb once
--     the threshold follows the measured background.
local dim = sample(80, 400, {22, 22, 22}, {{30, 41, 60, 300, 78, 78, 78}})
check('absolute threshold rejects dim thumb', module.find_thumb(dim, {x = 36, y = 380}, options) == nil)
local dim_action = module.analyse(dim, {x = 36, y = 380}, options)
check('adaptive threshold detects dim thumb', dim_action ~= nil,
    dim_action and dim_action.hit or 'nil')
check('background measured', dim.background and dim.background >= 20 and dim.background <= 30,
    dim.background)

-- 18. A wide bright area (panel, blurred world) is not a thumb even though it
--     is brighter than the surrounding frame.
local panel = sample(120, 400, {22, 22, 22}, {{20, 80, 60, 300, 96, 96, 96}})
check('wide bright panel rejected', module.find_thumb(panel, {x = 40, y = 380}, options) == nil)

-- 19. The pointer's sprite is coloured with a bright core (measured on the live
--     Armory capture: a 100 px blob, channel spread up to 91). It must not split
--     the thumb it is sitting on, and a press on the covered part is a grab.
local sprite = sample(150, 370, {37, 37, 37},
    {{78, 87, 86, 264, 149, 149, 149},
     {50, 110, 145, 215, 120, 60, 200},   -- coloured halo around the pointer
     {75, 90, 165, 185, 249, 249, 249}})  -- bright core
local sprite_found, sprite_reason = module.find_thumb(sprite, {x = 82, y = 170}, options)
check('coloured pointer does not split the thumb', sprite_found ~= nil
    and sprite_found.top == 86 and sprite_found.bottom == 264,
    sprite_found and (sprite_found.top .. '..' .. sprite_found.bottom) or sprite_reason)
local sprite_action = module.analyse(sprite, {x = 82, y = 170}, options)
check('press on a covered thumb is a grab', sprite_action and sprite_action.hit == 'thumb',
    sprite_action and sprite_action.hit)

-- 20. A press on the track below that thumb is still a track press: the same
--     coloured sprite must not turn the panel into a bar.
local sprite_low = module.analyse(sprite, {x = 82, y = 330}, options)
check('track press under the pointer is a page', sprite_low and sprite_low.hit == 'track',
    sprite_low and sprite_low.hit)

-- 21. Coloured artwork away from the pointer is not silently bridged: a wide
--     yellow band across the column splits the body instead of hiding inside it.
local coloured_break = sample(80, 400, {45, 45, 45},
    {{30, 41, 60, 300, 149, 149, 149}, {30, 41, 176, 196, 236, 226, 120}})
local break_found = module.find_thumb(coloured_break, {x = 36, y = 380}, options)
check('coloured band outside the pointer splits the body', break_found ~= nil
    and (break_found.bottom <= 175 or break_found.top >= 197),
    break_found and (break_found.top .. '..' .. break_found.bottom))

-- 21b. Which side of the bar holds the list, from the structure beside it: the
--      panel's own gradient must not count as content.
local sides = {
    {name = 'artwork left', side = 'left', patches = {
        {30, 41, 60, 300, 149, 149, 149}, {0, 12, 80, 280, 200, 200, 200}}},
    {name = 'artwork right', side = 'right', patches = {
        {30, 41, 60, 300, 149, 149, 149}, {60, 75, 80, 280, 200, 200, 200}}},
    {name = 'panel both sides', side = nil, patches = {
        {30, 41, 60, 300, 149, 149, 149}}},
    {name = 'brightness step right is content', side = 'right', patches = {
        {30, 41, 60, 300, 149, 149, 149}, {59, 79, 0, 400, 70, 70, 70}}},
    {name = 'a shaded panel is not content', side = nil, patches = {
        {30, 41, 60, 300, 149, 149, 149}}, shaded = true},
}
for _, case in ipairs(sides) do
    local background = case.shaded and {60, 60, 60} or {45, 45, 45}
    local frame = sample(80, 400, background, case.patches)
    local action = module.analyse(frame, {x = 35, y = 200}, options)
    local got = action and action.bar.side or nil
    check('side detection: ' .. case.name, got == case.side, tostring(got))
end

-- 22. Geometry follows the display height: the constants were measured on a
--     1440 px tall viewport, so a 2160p viewport must scale them and a 720p one
--     must shrink them.
check('reference scale is one', module.scale_for_height(1440) == 1)
check('missing height keeps the reference', module.scale_for_height(nil) == 1
    and module.scale_for_height(100) == 1)
check('2160p scale', math.abs(module.scale_for_height(2160) - 1.5) < 0.001,
    module.scale_for_height(2160))
check('720p scale', math.abs(module.scale_for_height(720) - 0.5) < 0.001,
    module.scale_for_height(720))
check('scale is bounded', module.scale_for_height(8640) == 4 and module.scale_for_height(240) == 0.4)

local reference = module.parse_settings(nil, nil)
local big = module.scale_settings(reference, module.scale_for_height(2160))
check('window scales with the display', big.window == 690, big.window)
check('strip scales with the display', big.strip_width == 144, big.strip_width)
check('pointer box scales with the display', big.cursor_mask_radius == 108
    and big.cursor_mask.x1 == 108 and big.cursor_mask.y0 == -108,
    big.cursor_mask_radius)
check('bar size limits scale with the display', big.max_width == 42 and big.min_width == 9
    and big.min_height == 66, big.max_width .. '/' .. big.min_width .. '/' .. big.min_height)
-- The wheel step is *not* display-scaled: the live machine showed the same 13 px
-- step with a 1440 px client and a 998 px one, so the seed stays at the measured
-- reference value and is scaled at use time by the bar's measured thickness.
check('tolerances scale but the step seed does not', big.default_pixels_per_notch == 13
    and big.center_tolerance == 6 and big.drag_threshold == 15,
    big.default_pixels_per_notch .. '/' .. big.center_tolerance)
check('the reference bar thickness is a setting', reference.bar_reference_width == 10
    and reference.drag_column_margin == 2.8,
    reference.bar_reference_width .. '/' .. reference.drag_column_margin)
check('brightness and timing do not scale', big.min_luma == 105 and big.max_luma == 220
    and big.jump_max_notches == 120 and big.settle_delay_ms == 200 and big.max_spread == 18)

local small = module.scale_settings(reference, module.scale_for_height(720))
check('720p shrinks the same way', small.window == 230 and small.strip_width == 48
    and small.cursor_mask_radius == 36 and small.max_width == 14,
    small.window .. '/' .. small.strip_width .. '/' .. small.cursor_mask_radius)

-- 23. Values typed into the ini are absolute: they must survive scaling, and a
--     tighter window_max must not be widened by it.
local pinned = module.parse_settings('window=700\ncursor_mask_radius=90\nmax_width=64\nwindow_max=700\n', nil)
check('ini keys are marked as overrides', pinned.overridden.window == true
    and pinned.overridden.max_width == true and pinned.overridden.min_width == nil)
local pinned_scaled = module.scale_settings(pinned, 2)
check('ini geometry stays absolute', pinned_scaled.window == 700 and pinned_scaled.max_width == 64
    and pinned_scaled.window_max == 700, pinned_scaled.window .. '/' .. pinned_scaled.max_width
    .. '/' .. pinned_scaled.window_max)
check('unset keys still scale', pinned_scaled.strip_width == 192
    and pinned_scaled.cursor_mask_radius == 90, pinned_scaled.strip_width .. '/'
    .. pinned_scaled.cursor_mask_radius)
check('scaled settings stay clamped', module.scale_settings(reference, 4).window <= 1400
    and module.scale_settings(reference, 4).strip_width <= 240
    and module.scale_settings(reference, 4).max_width <= 80)
check('window_max never undercuts window', module.parse_settings('window=900\nwindow_max=200\n', nil).window_max == 900)
check('scaling can be disabled', module.parse_settings('scale_geometry=0\n', nil).scale_geometry == 0)

print(string.format('detector: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
