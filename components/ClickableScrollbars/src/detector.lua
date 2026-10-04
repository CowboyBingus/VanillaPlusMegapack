-- The legacy pixel detector. No runtime path enters it: the runtime acts only
-- on a native owner. It stays for the offline tests.
local module, cs = ...
local clamp = cs.clamp

-- ---------------------------------------------------------------- detection

local function luminance(r, g, b)
    return (r * 299 + g * 587 + b * 114) / 1000
end

-- A capture sample exposes width, height, origin_x, origin_y and
-- rgb(x, y) -> r, g, b for strip-local coordinates.

function module.thumb_pixel(sample, x, y, options)
    local r, g, b = sample.rgb(x, y)
    if r == nil then return nil end
    local high, low = r, r
    if g > high then high = g end
    if b > high then high = b end
    if g < low then low = g end
    if b < low then low = b end
    if high - low > options.max_spread then return nil end
    local value = luminance(r, g, b)
    if value < options.min_luma or value > options.max_luma then return nil end
    return value
end

local function raw_luma(sample, x, y)
    local r, g, b = sample.rgb(x, y)
    if r == nil then return nil end
    return luminance(r, g, b)
end

-- True when a pixel can be read as track: neutral, and darker than the thumb
-- window. A pixel that is neither track nor a thumb pixel (coloured, or
-- brighter than the accepted window) is unjudgeable rather than background.
function module.track_pixel(sample, x, y, options)
    local r, g, b = sample.rgb(x, y)
    if r == nil then return false end
    local high, low = r, r
    if g > high then high = g end
    if b > high then high = b end
    if g < low then low = g end
    if b < low then low = b end
    if high - low > options.max_spread then return false end
    return luminance(r, g, b) < options.min_luma
end

-- Coarse brightness of a capture, used to detect a black frame (a GDI capture
-- that never sees the rendered game, e.g. under an overlay plane).
function module.strip_luminance(sample)
    local step_x = math.max(1, math.floor(sample.width / 24))
    local step_y = math.max(1, math.floor(sample.height / 24))
    local total, count = 0, 0
    for y = 0, sample.height - 1, step_y do
        for x = 0, sample.width - 1, step_x do
            local value = raw_luma(sample, x, y)
            if value then
                total = total + value
                count = count + 1
            end
        end
    end
    if count == 0 then return nil end
    return total / count
end

-- Dark-quartile luminance of a capture, used to place the thumb threshold
-- relative to the frame the game actually produced. Bright menus are ignored
-- by taking a low quantile instead of the mean.
function module.background_luminance(sample, quantile)
    local step_x = math.max(1, math.floor(sample.width / 32))
    local step_y = math.max(1, math.floor(sample.height / 32))
    local histogram, total = {}, 0
    for y = 0, sample.height - 1, step_y do
        for x = 0, sample.width - 1, step_x do
            local value = raw_luma(sample, x, y)
            if value then
                local bucket = math.floor(value / 8)
                histogram[bucket] = (histogram[bucket] or 0) + 1
                total = total + 1
            end
        end
    end
    if total == 0 then return nil end
    local target = math.max(1, math.floor(total * (quantile or 0.25)))
    local seen = 0
    for bucket = 0, 31 do
        seen = seen + (histogram[bucket] or 0)
        if seen >= target then return bucket * 8 + 4 end
    end
    return 255
end

-- Per-capture copy of the settings with the thumb brightness window adapted to
-- the measured background, so a dim GDI capture of an HDR frame behaves like
-- the bright reference screenshots.
function module.adapt_options(sample, options)
    local background = module.background_luminance(sample)
    if background == nil then return options, nil end
    local tuned = {}
    for key, value in pairs(options) do tuned[key] = value end
    tuned.min_luma = math.max(options.min_luma_floor or 40, background + (options.min_contrast or 30))
    if tuned.min_luma > 240 then tuned.min_luma = 240 end
    return tuned, background
end

local function cursor_masked(cursor, mask, x, y)
    -- A missing or malformed cursor means "no mask": the detector then judges
    -- every pixel instead of raising, which keeps a caller mistake diagnostic
    -- rather than fatal.
    if not cursor or type(cursor.x) ~= 'number' or type(cursor.y) ~= 'number' then return false end
    if not mask or type(mask.x0) ~= 'number' then return false end
    return x >= cursor.x + mask.x0 and x <= cursor.x + mask.x1
        and y >= cursor.y + mask.y0 and y <= cursor.y + mask.y1
end

-- Cheap column probe: a thumb column must show at least two thumb rows and one
-- clearly darker row, which a wall of bright stripes cannot. Columns that pass
-- are scanned in full, so the result matches a full scan.
local function column_probe(sample, cursor, x, options) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    local step = options.probe_step or 0
    if step <= 1 then return true, true end
    local offset = options.local_offset or 16
    local grey, lightest, darkest = 0, nil, nil
    for y = 0, sample.height - 1, step do
        if not cursor_masked(cursor, options.cursor_mask, x, y) then
            local value = module.thumb_pixel(sample, x, y, options)
            if value then
                local accepted = value
                if options.local_contrast then
                    accepted = nil
                    local left, right = raw_luma(sample, x - offset, y), raw_luma(sample, x + offset, y)
                    if left or right then
                        local beside = ((left or right) + (right or left)) / 2
                        if value - beside >= options.min_contrast then accepted = value end
                    end
                end
                if accepted then
                    grey = grey + 1
                    if not lightest or accepted < lightest then lightest = accepted end
                else
                    local luma = raw_luma(sample, x, y)
                    if luma and (not darkest or luma < darkest) then darkest = luma end
                end
            else
                local luma = raw_luma(sample, x, y)
                if luma and (not darkest or luma < darkest) then darkest = luma end
            end
            local panel = darkest ~= nil and lightest ~= nil
                and darkest <= lightest - options.min_contrast
            if grey >= 2 and panel then return true, true end
        end
    end
    local panel = darkest ~= nil and lightest ~= nil
        and darkest <= lightest - options.min_contrast
    return false, panel
end

-- Every accepted vertical run in one column, bridging rows hidden by the cursor.
local function scan_column(sample, cursor, x, options) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    local runs, start, grey, filled, bridge, gap, last_grey = {}, nil, 0, 0, 0, 0, nil
        local run_masked = false
        local function close(ending)
            if not start then return end
            -- Masked or interrupted rows only count as part of the thumb when
            -- another thumb pixel follows them.
            filled = filled - gap
            ending = math.min(ending, (last_grey or start) + 1)
            local length = ending - start
            if length >= options.min_height and length <= sample.height * options.max_height_ratio
                and grey >= filled * options.min_fill then
                -- Clipped by the glow or the capture edge: the hidden part is inferred, not read.
                local clipped_top = cursor_masked(cursor, options.cursor_mask, x, start - 1)
                    or start <= 0
                local clipped_bottom = cursor_masked(cursor, options.cursor_mask, x, ending)
                    or ending >= sample.height
                runs[#runs + 1] = {top = start, bottom = ending - 1,
                                   clipped_top = clipped_top and true or false,
                                   clipped_bottom = clipped_bottom and true or false,
                                   -- Only a clipped end makes the extent
                                   -- untrustworthy; a hidden middle does not.
                                   masked = (clipped_top or clipped_bottom) and true or false}
            end
            start, grey, filled, bridge, gap, last_grey = nil, 0, 0, 0, 0, nil
            run_masked = false
        end
        for y = 0, sample.height - 1 do
            local covered = cursor_masked(cursor, options.cursor_mask, x, y)
            local value = covered and nil or module.thumb_pixel(sample, x, y, options)
            if value and options.local_contrast then
                -- Wide bright areas (panels, blurred background) must not
                -- look like a thumb: require clearly darker pixels beside
                -- the column at the same row.
                local offset = options.local_offset or 16
                local left, right = raw_luma(sample, x - offset, y), raw_luma(sample, x + offset, y)
                if not left and not right then
                    value = nil
                else
                    local beside = ((left or right) + (right or left)) / 2
                    if value - beside < options.min_contrast then value = nil end
                end
            end
            if not value and covered and not module.track_pixel(sample, x, y, options) then
                -- Hidden by the pointer, not missing: the run keeps going through it.
                if start then
                    bridge = bridge + 1
                    run_masked = true
                    if bridge > options.max_bridge then
                        start, grey, filled, bridge, gap, last_grey = nil, 0, 0, 0, 0, nil
                        run_masked = false
                    end
                end
            else
                bridge = 0
                if value then
                    if not start then start, grey, filled, gap = y, 0, 0, 0 end
                    grey, filled, gap, last_grey = grey + 1, filled + 1, 0, y
                elseif start then
                    gap = gap + 1
                    filled = filled + 1
                    if gap > options.max_gap then close(y - gap + 1) end
                end
            end
        end
    close(sample.height)
    return runs
end

-- Longest vertical grey run per column, bridging rows hidden by the cursor.
-- Columns that cannot hold a thumb anywhere are rejected by the cheap probe, so
-- a strip that is mostly panel costs a fraction of a full scan.
local function column_runs(sample, cursor, options) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    local columns = {}
    local candidates = {}
    for x = 0, sample.width - 1 do
        local candidate, panel = column_probe(sample, cursor, x, options)
        if candidate or panel then
            candidates[#candidates + 1] = {x = x, panel = panel and true or false}
        end
    end
    -- A bar is only ever accepted in the pointer's own column, so when a screen
    -- is covered in bar-like structures the columns nearest the pointer are the
    -- ones worth scanning. This bounds the scan work no matter what is on screen.
    local limit = (options.probe_max_columns or ((options.max_width or 28) + 8))
    if #candidates > limit then
        local cursor_x = cursor and cursor.x or math.floor(sample.width / 2)
        table.sort(candidates, function(a, b)
            if a.panel ~= b.panel then return a.panel end
            return math.abs(a.x - cursor_x) < math.abs(b.x - cursor_x)
        end)
        for index = #candidates, limit + 1, -1 do candidates[index] = nil end
    end
    for index = 1, #candidates do
        local x = candidates[index].x
        local runs = scan_column(sample, cursor, x, options)
        if #runs > 0 then columns[x] = runs end
    end
    return columns
end

local function overlaps(first, second)
    local top = math.max(first.top, second.top)
    local bottom = math.min(first.bottom, second.bottom)
    if bottom < top then return false end
    local shortest = math.min(first.bottom - first.top, second.bottom - second.top)
    if shortest <= 0 then return false end
    return (bottom - top) >= shortest * 0.6
end

-- A thumb is uniform along its length and clearly darker-edged on both sides.
-- Rows hidden by the cursor's glow are skipped rather than judged.
local function bar_quality(sample, bar, options, cursor) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    local height = bar.bottom - bar.top + 1
    local middle = math.floor((bar.left + bar.right) / 2)
    local values, count = {}, 0
    for y = bar.top, bar.bottom, 3 do
        local value = nil
        if not cursor_masked(cursor, options.cursor_mask, middle, y) then
            value = module.thumb_pixel(sample, middle, y, options)
        end
        if value then
            count = count + 1
            values[#values + 1] = value
        end
    end
    if count < 4 then return false, 'sparse' end
    table.sort(values)
    local median = values[math.floor((count + 1) / 2)]
    local near = 0
    for index = 1, #values do
        if math.abs(values[index] - median) <= options.max_variance then near = near + 1 end
    end
    if near < count * options.min_uniformity then return false, 'not_uniform' end
    local best = nil
    for y = bar.top + 4, bar.bottom - 4, 7 do
        if not cursor_masked(cursor, options.cursor_mask, middle, y) then
            local outside, sides = 0, 0
            for _, range in ipairs({{bar.left - 3, bar.left - 1}, {bar.right + 1, bar.right + 3}}) do
                local total, samples = 0, 0
                for x = range[1], range[2] do
                    local value = raw_luma(sample, x, y)
                    if value then
                        total = total + value
                        samples = samples + 1
                    end
                end
                if samples > 0 then
                    outside = outside + total / samples
                    sides = sides + 1
                end
            end
            if sides > 0 then
                local value = outside / sides
                if not best or value < best then best = value end
            end
        end
    end
    if best and best > median - options.edge_contrast then
        return false, 'no_edge'
    end
    return true, median, height
end

-- Merge per-column runs into candidate bars. `band`, when given, selects the
-- bar overlapping those strip-local x coordinates instead of the cursor.
function module.find_thumb(sample, cursor, options, band) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    local columns = column_runs(sample, cursor, options)
    local bars, current = {}, nil
    for x = 0, sample.width - 1 do
        local runs = columns[x]
        local best = nil
        if runs then
            -- The cursor glow can split one thumb into two runs inside the same
            -- column; when both parts face the gap, they are one bar.
            local merged = {}
            for index = 1, #runs do
                local run = runs[index]
                local previous = merged[#merged]
                if previous and previous.clipped_bottom and run.clipped_top
                    and (run.top - previous.bottom) <= options.max_bridge then
                    previous.bottom = run.bottom
                    previous.clipped_bottom = run.clipped_bottom
                    previous.masked = previous.clipped_top or previous.clipped_bottom
                else
                    merged[#merged + 1] = {top = run.top, bottom = run.bottom,
                                           clipped_top = run.clipped_top,
                                           clipped_bottom = run.clipped_bottom,
                                           masked = run.masked}
                end
            end
            for index = 1, #merged do
                local run = merged[index]
                if not best or (run.bottom - run.top) > (best.bottom - best.top) then best = run end
            end
        end
        if best then
            if current and current.right == x - 1 and overlaps(current, best) then
                current.right = x
                if best.masked then current.masked = true end
                if best.clipped_top then current.clipped_top = true end
                if best.clipped_bottom then current.clipped_bottom = true end
                if best.top < current.top then current.top = best.top end
                if best.bottom > current.bottom then current.bottom = best.bottom end
            else
                if current then bars[#bars + 1] = current end
                current = {left = x, right = x, top = best.top, bottom = best.bottom,
                           masked = best.masked or false,
                           clipped_top = best.clipped_top or false,
                           clipped_bottom = best.clipped_bottom or false}
            end
        elseif current then
            bars[#bars + 1] = current
            current = nil
        end
    end
    if current then bars[#bars + 1] = current end

    local chosen, chosen_distance = nil, nil
    for index = 1, #bars do
        local bar = bars[index]
        local width = bar.right - bar.left + 1
        local height = bar.bottom - bar.top + 1
        if width >= options.min_width and width <= options.max_width and height >= options.min_height then
            local good, median = bar_quality(sample, bar, options, cursor)
            if good then bar.median = median end
            if not good then bar = nil end
        else
            bar = nil
        end
        if bar then
            if band then
                local overlap = math.min(bar.right, band.right) - math.max(bar.left, band.left) + 1
                if overlap > 0 then
                    local distance = -overlap
                    if not chosen or distance < chosen_distance then
                        chosen, chosen_distance = bar, distance
                    end
                end
            else
                local gap = 0
                if cursor.x < bar.left then gap = bar.left - cursor.x
                elseif cursor.x > bar.right then gap = cursor.x - bar.right end
                if gap <= options.column_tolerance then
                    local distance = gap * 4 + math.abs(cursor.y - clamp(cursor.y, bar.top, bar.bottom))
                    if not chosen or distance < chosen_distance then
                        chosen, chosen_distance = bar, distance
                    end
                end
            end
        end
    end
    if not chosen then return nil, 'no_thumb', bars end
    return chosen, nil, bars
end

-- Which side of the bar holds the list: artwork, spine and groove sit on the
-- list's side, panel on the other. Returns 'left', 'right' or nil; it is recorded
-- in the log, where it tells a reader which way the list lies from the bar.
function module.content_side(sample, bar, options)
    local reach = math.min(44, math.max(8, options.strip_width or 96))
    -- The answer only has to separate panel from content, and the scan must not
    -- grow with a thumb that fills the capture.
    local stride = math.max(4, math.floor((bar.bottom - bar.top + 1) / 48))
    -- Structure, not brightness: the panel beside a bar carries its own gradient,
    -- so a column is content when it stands out from its neighbours, not when it
    -- is brighter than them.
    local function relief(from, to)
        local means = {}
        for x = from, to do
            local total, count = 0, 0
            for y = bar.top, bar.bottom, stride do
                local value = raw_luma(sample, x, y)
                if value then
                    total = total + value
                    count = count + 1
                end
            end
            means[#means + 1] = count > 0 and total / count or nil
        end
        local best = 0
        for index = 2, #means - 1 do
            local left, middle, right = means[index - 1], means[index], means[index + 1]
            if left and middle and right then
                local step = math.abs(middle - (left + right) / 2)
                if step > best then best = step end
            end
        end
        return best
    end
    local left = relief(math.max(0, bar.left - reach), bar.left - 2)
    local right = relief(bar.right + 2, math.min(sample.width - 1, bar.right + reach))
    if left > right + 12 then return 'left' end
    if right > left + 12 then return 'right' end
    return nil
end

-- 'thumb' for a press on the visible bar, 'track' for the invisible track beside
-- it, nil for list content. The direction comes from the tracked thumb.
function module.decide(bar, cursor, sample, options)
    if cursor.y >= bar.top - options.thumb_margin and cursor.y <= bar.bottom + options.thumb_margin then
        return 'thumb', 'thumb'
    end
    local r, g, b = sample.rgb(cursor.x, cursor.y)
    if r ~= nil then
        local value = luminance(r, g, b)
        local bar_value = module.thumb_pixel(sample, bar.left + math.floor((bar.right - bar.left) / 2),
                                             bar.top + 2, options)
            or options.min_luma
        if value > bar_value - options.click_contrast then
            return nil, 'click_not_on_track'
        end
    end
    return 'track', 'track'
end

function module.analyse(sample, cursor, options, band)
    -- A caller that cannot supply a cursor gets a reason instead of a raise:
    -- every decision below depends on knowing where the pointer is.
    if not cursor or type(cursor.x) ~= 'number' or type(cursor.y) ~= 'number' then
        return nil, 'no_cursor'
    end
    options, sample.background = module.adapt_options(sample, options)
    local bar, reason, candidates = module.find_thumb(sample, cursor, options, band)
    if not bar then return nil, reason, candidates end
    bar.side = module.content_side(sample, bar, options)
    local hit, why = module.decide(bar, cursor, sample, options)
    if not hit then return nil, why, bar end
    return {bar = bar, hit = hit}, why
end
