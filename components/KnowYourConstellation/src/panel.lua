-- Forecast panel: a gold-framed box hanging below the native planet,
-- operation or briefing panel (sharing its bottom stroke). It may cover the
-- squad list while a mission is highlighted, so it draws on a high layer; it
-- stops above the bottom prompt row. Beside the native panel is the last
-- resort when even that height is too short. GUI objects are retained:
-- nothing is measured or redrawn unless the report, geometry or font changes,
-- except one text update per frame while a long headline scrolls. Text is
-- UTF-8 in any script: it is measured, wrapped and scrolled by character,
-- never by byte (bingus_text.lua).
local text = assert(..., 'bingus_text required')
local M = {}

-- Expected transient states, while the game builds or switches screens, are
-- raised as constant tables {pending = reason, status = 'hidden: ' .. reason}:
-- a waiting frame builds no string, and the installer hides and retries on the
-- next frame without counting the frame toward stopping the mod (as v4.0 did
-- for every raised frame). Everything else raises a string and counts.
local function pending(reason) return {pending = reason, status = 'hidden: ' .. reason} end
M.PENDING = {
    worlds = pending('UI worlds unavailable'),
    gui = pending('Could not create forecast panel'),
    material = pending('Font material unavailable'),
    metrics = pending('Font metrics unavailable'),
    caret = pending('Font caret unavailable'),
    rect = pending('Retained rectangle unavailable'),
    text = pending('Retained text unavailable'),
    native = pending('Native panel unavailable'),
    viewport = pending('Forecast exceeds viewport'),
}
local PENDING = M.PENDING

-- UI units at scale 1; the native frame is 533 wide.
M.BOTTOM = 56             -- keep the Esc / Back prompt row visible
-- Native frame geometry: a 3-unit gold outline, a 4-unit dark gap, then the
-- opaque body 7 units from the outer edge. Text starts 22 units in, in line
-- with the native panel text above.
M.BORDER, M.INSET, M.PAD, M.GAP, M.EDGE = 3, 7, 22, 6, 5
M.SIZES = {18, 16, 14, 12}
M.TITLE, M.CAPTION = 18, 13
-- Line pitch of meter rows and list lines, in text sizes.
M.ROW, M.LINE = 1.4, 1.3
-- Capital height, in text sizes: sets the padding above the label's capitals,
-- which the space below the footer's baseline mirrors.
M.CAP = 0.7
M.TICK, M.TICK_GAP, M.TICKS = 8, 3, 10
-- Body and slate (rules, empty ticks). The war-table UI shows dark colours
-- lighter than their values: the native body, (15, 20, 30), shows as about
-- (32, 37, 49). These show as the mockup's #0F141E and #3B4654.
M.BODY, M.SLATE = {6, 10, 17}, {42, 53, 69}
-- A headline wider than the panel scrolls like native long strings: it holds
-- at the start, scrolls to the end, holds, then resets. Speed in units/s.
M.SCROLL = {hold=2.0, end_hold=1.5, speed=40}
-- Draw layers. GUI layers sort across every GUI in a world and only 0-1023
-- order correctly (1024 and above wrap under the box in game). The squad
-- nameplates draw above 1000 and below 1011 (probed in game), so the box
-- covers them while a mission is highlighted. Masks hide scrolling glyphs in
-- the side padding.
M.LAYER = {shade=1011, body=1012, rule=1013, border=1013, content=1014, mask=1015}

-- Tick and gap widths in whole pixels. Fractional sizes would round to
-- uneven gaps (ticks seen in pairs), so every tick and gap is identical.
function M.tick_pixels(s)
    return math.max(1, math.floor(M.TICK * s + 0.5)), math.max(1, math.floor(M.TICK_GAP * s + 0.5))
end

function M.meter_width(s)
    local tick, gap = M.tick_pixels(s)
    return M.TICKS * tick + (M.TICKS - 1) * gap
end

-- Lines break at spaces and between CJK characters, never inside a character.
M.wrap = text.wrap

-- Scroll distance from the start at `time` seconds into a cycle, for text
-- `travel` units wider than its window, and the cycle length.
function M.scroll_offset(time, travel, s)
    local hold, speed = M.SCROLL.hold, M.SCROLL.speed * s
    local moving = travel / speed
    local period = hold + moving + M.SCROLL.end_hold
    time = time % period
    if time < hold then return 0, period end
    if time < hold + moving then return (time - hold) * speed, period end
    return travel, period
end

-- Characters drawn at scroll `offset`: those wholly inside the window widened
-- by `margin` on each side, where the masks hide them. `edges[k]` is the caret
-- before character k. Continues from (first, last) found at a smaller or equal
-- offset, or from the start without them. Returns the first character and the
-- one after the last.
function M.window(edges, count, offset, width, margin, first, last)
    first, last = first or 1, last or 1
    while first <= count and edges[first] < offset - margin do first = first + 1 end
    if last < first then last = first end
    while last <= count and edges[last + 1] <= offset + width + margin do last = last + 1 end
    return first, last
end

-- Moves scroll state `m` to its current time. Returns the visible text and
-- its x position, or nil when nothing moved since the last call. `m.bounds[k]`
-- is the byte where character k starts (then #text + 1), so a window never
-- cuts a character. Window strings are cached, so later cycles create no
-- strings.
function M.advance(m)
    local offset, period = M.scroll_offset(m.time, m.travel, m.scale)
    if m.time >= period then m.time = m.time - period end
    if offset == m.offset then return nil end
    if not m.offset or offset < m.offset then m.first, m.last = nil, nil end
    m.offset = offset
    m.first, m.last = M.window(m.edges, #m.bounds - 1, offset, m.width, m.margin, m.first, m.last)
    local key = m.first * 1024 + m.last
    local value = m.windows[key]
    if not value then
        value = m.text:sub(m.bounds[m.first], m.bounds[m.last] - 1)
        m.windows[key] = value
    end
    return value, m.x + m.edges[m.first] - offset
end

-- Lays out one report at body size `size`. Offsets are distances below the
-- content top (y grows downward here). Returns nil when it needs more than
-- `limit` height. `shown_large`/`shown_small` limit the listed enemies; the
-- rest are counted in an "and N more" line (model.more, with {count}).
function M.plan(model, measure, width, limit, s, size, shown_large, shown_small)
    local items, d = {}, 0
    local function add(value, text_size, x, role)
        items[#items + 1] = {kind='text', text=value, size=text_size, x=x, d=d + text_size, role=role}
    end
    local title = M.TITLE * s
    add(model.label, title, 0, 'label')
    d = d + title * 1.3
    if model.headline then
        -- One line at the title size; wider headlines scroll.
        add(model.headline, title, 0, 'body')
        local overflow = measure(model.headline, title) - width
        if overflow > 0 then items[#items].kind, items[#items].travel = 'scroll', overflow end
        d = d + title * 1.25
    end
    local row, line = size * M.ROW, size * M.LINE
    local caption = M.CAPTION * s
    local function section(left, right)
        d = d + M.GAP * s
        add(left, caption, 0, 'muted')
        add(right, caption, width - measure(right, caption), 'muted')
        d = d + caption * 1.2
        items[#items + 1] = {kind='rule', d=d, h=math.max(1, s)}
        d = d + 3 * s
    end
    local large, small = model.large or {}, model.small or {}
    shown_large = math.min(shown_large or #large, #large)
    shown_small = math.min(shown_small or #small, #small)
    if shown_large > 0 then
        section(model.large_caption, model.rate_caption)
        for i = 1, shown_large do
            local entry = large[i]
            -- A name that would reach the meter needs a smaller size.
            if measure(entry.text, size) > width - M.meter_width(s) - 2 * M.GAP * s then return nil end
            add(entry.text, size, 0, 'body')
            -- Ticks slightly taller than the capitals beside them, centred on them.
            items[#items + 1] = {kind='meter', ticks=entry.ticks, x=width - M.meter_width(s),
                d=d + size * 1.05, h=size * 0.8}
            d = d + row
        end
    end
    local hidden = (#large - shown_large) + (#small - shown_small)
    if shown_small > 0 or hidden > 0 then
        local names = {}
        for i = 1, shown_small do names[i] = small[i] end
        if shown_small > 0 then section(model.small_caption, model.order_caption) end
        local separator = model.separator or ', '
        local list = table.concat(names, separator)
        if hidden > 0 then
            local more = text.format(model.more or 'and {count} more', {count = hidden})
            list = (list == '' and '' or list .. separator) .. more
        end
        for _, value in ipairs(M.wrap(list, width, function(v) return measure(v, size) end)) do
            add(value, size, 0, 'body')
            d = d + line
        end
    end
    d = d + M.GAP * s
    local footer = M.CAPTION * s
    add(model.footer, footer, 0, 'muted')
    -- End as far below the footer's baseline as the label's capitals start
    -- below the top, so both ends get the same padding.
    d = d + footer + title * (1 - M.CAP)
    if d > limit then return nil end
    return {items=items, size=size, height=d}
end

-- Largest body size that fits. With `cut`, the lists may then be shortened
-- from the end and summarised as "and N more" at the smallest size.
function M.fit(model, measure, width, limit, s, cut)
    for _, size in ipairs(M.SIZES) do
        local plan = M.plan(model, measure, width, limit, s, size * s)
        if plan then return plan end
    end
    if not cut then return nil end
    local size = M.SIZES[#M.SIZES] * s
    local large, small = #(model.large or {}), #(model.small or {})
    for k = small - 1, 0, -1 do
        local plan = M.plan(model, measure, width, limit, s, size, large, k)
        if plan then return plan end
    end
    for k = large - 1, 0, -1 do
        local plan = M.plan(model, measure, width, limit, s, size, k, 0)
        if plan then return plan end
    end
    return nil
end

-- Chrome around the content: border, inset and inner padding on each side.
local function chrome(s) return 2 * (M.BORDER + M.INSET + M.EDGE) * s end

-- Below the native panel when the content fits above the bottom prompt row,
-- otherwise beside it with the full screen height.
function M.place(anchor, width, height, plan_below, plan_side)
    local s = anchor.scale
    if plan_below then
        local h = plan_below.height + chrome(s)
        return {side=false, x=anchor.x, y=anchor.y + M.BORDER * s - h, w=anchor.w, h=h}, plan_below
    end
    local plan = plan_side
    if not plan then error(PENDING.viewport) end
    local h = plan.height + chrome(s)
    local x = anchor.x + anchor.w + 12 * s
    if x + anchor.w > width - 12 * s then x = anchor.x - anchor.w - 12 * s end
    local y = math.min(height - 12 * s, anchor.y + anchor.h) - h
    if x < 0 or y < 0 then error(PENDING.viewport) end
    return {side=true, x=x, y=y, w=anchor.w, h=h}, plan
end

function M.below_limit(anchor)
    local s = anchor.scale
    return anchor.y + M.BORDER * s - M.BOTTOM * s - chrome(s)
end

function M.side_limit(anchor, height)
    local s = anchor.scale
    return math.min(height - 12 * s, anchor.y + anchor.h) - 12 * s - chrome(s)
end

function M.new(engine)
    local self = {cache={}, order={}, rect_ids={}, text_ids={}}
    local App, World, Gui = engine.Application, engine.World, engine.Gui
    local function colour(a, r, g, b) return engine.Color(a, r, g, b) end
    local function vector(x, y, z) return engine.Vector3(x, y, z or 0) end
    local function worlds()
        local list = App.worlds()
        if not list then error(PENDING.worlds) end
        return list
    end
    local function contains(list, value)
        for _, v in ipairs(list) do if v == value then return true end end
        return false
    end
    local function wipe(t)
        for key in pairs(t) do t[key] = nil end
    end
    -- Drops the GUI, destroying it only while its world is still listed
    -- (`list`: this frame's world list, when the caller already has it). The
    -- tables are emptied in place, so the hidden frames, which clear every
    -- frame, allocate nothing.
    local function destroy(list)
        if self.gui and contains(list or worlds(), self.world) then World.destroy_gui(self.world, self.gui) end
        self.gui, self.world, self.font, self.scroll = nil, nil, nil, nil
        wipe(self.rect_ids) wipe(self.text_ids)
        self.signature = nil
    end
    local function clear(list)
        destroy(list)
        self.model, self.geometry = nil, nil
        wipe(self.cache) wipe(self.order)
    end
    function self:clear() clear() end
    -- Mirror native normal-font setup on one of our GUI materials.
    local function ink(gui, anchor)
        local material = Gui.material(gui, engine.IdString64.from_hex(anchor.material))
        if not material then error(PENDING.material) end
        local function slot(hash) return engine.IdString64.from_hex(hash .. '00000000') end
        for _, hash in ipairs({'8035c266', '5e8455fe', '309e7783', '82b803a8'}) do
            engine.Material.set_scalar(material, slot(hash), 0)
        end
        engine.Material.set_vector2(material, slot('e13777ce'), engine.Vector2(1, -1))
        engine.Material.set_vector4(material, slot('7701209e'), colour(0, 0, 0, 0))
        engine.Material.set_texture(material, slot('88bac99b'), engine.IdString64.from_hex(anchor.atlas))
    end
    -- Every frame the panel is up, the world list is checked again: a world
    -- that was replaced or removed moves or hides the panel on that frame.
    local function prepare(anchor)
        -- The first non-main world is the only UI world drawn on the war table.
        local main, target = App.main_world(), nil
        local list = worlds()
        for _, world in ipairs(list) do
            if world ~= main then target = world break end
        end
        if not target then clear(list) return nil end
        if self.world and self.world ~= target then clear(list) end
        if not self.gui or self.font ~= anchor.font or self.material ~= anchor.material or self.atlas ~= anchor.atlas then
            destroy(list)
            self.gui = World.create_screen_gui(target, 'scale', 1, 1)
            if not self.gui then error(PENDING.gui) end
            self.world = target
            ink(self.gui, anchor)
            self.font, self.material, self.atlas = anchor.font, anchor.material, anchor.atlas
        end
        return target
    end
    local function measurer(font)
        local measured = {}
        return function(value, size)
            local key = size .. '|' .. value
            if not measured[key] then
                local lo, hi, caret = Gui.text_extents(self.gui, value, font, size)
                if not (lo and hi and caret) then error(PENDING.metrics) end
                measured[key] = math.max(engine.Vector2.x(hi), engine.Vector2.x(caret)) - math.min(0, engine.Vector2.x(lo))
            end
            return measured[key]
        end
    end
    -- Carets before each character and after the last, never decreasing:
    -- one measurement per character (a CJK character is 3 bytes, one glyph).
    local function carets(value, bounds, font, size)
        local edges = {0}
        for k = 2, #bounds do
            local _, _, caret = Gui.text_extents(self.gui, value:sub(1, bounds[k] - 1), font, size)
            if not caret then error(PENDING.caret) end
            edges[k] = math.max(edges[k - 1], engine.Vector2.x(caret))
        end
        return edges
    end
    -- Plans are cached per report, width, height limit, scale and mode (8 entries).
    local function planned(model, font, width, limit, s, cut)
        local key = table.concat({model.signature or 'pending', self.font, width, limit, s, tostring(cut)}, '|')
        local plan = self.cache[key]
        if plan == nil then
            plan = M.fit(model, measurer(font), width, limit, s, cut) or false
            self.cache[key] = plan
            self.order[#self.order + 1] = key
            if #self.order > 8 then self.cache[table.remove(self.order, 1)] = nil end
        end
        return plan or nil
    end
    local palette = {
        label=function() return colour(255, 255, 213, 0) end,
        body=function() return colour(255, 240, 243, 245) end,
        muted=function() return colour(255, 179, 198, 205) end,
    }
    -- One frame of a scrolling headline: no GUI call while it holds still.
    -- Engine IDs are temporary, so they are rebuilt from the hex names.
    local function scroll(dt)
        local m = self.scroll
        m.time = m.time + math.max(0, math.min(dt or 0, 0.1))
        local value, x = M.advance(m)
        if not value then return end
        Gui.update_text(self.gui, m.id, value, engine.IdString64.from_hex(self.font), m.size,
            engine.IdString64.from_hex(self.material), vector(x, m.y, M.LAYER.content), palette.body())
    end
    local function draw(plan, place, anchor, font_id, material_id)
        local s, gui, layer = anchor.scale, self.gui, M.LAYER
        local rect_index, text_index = 0, 0
        local function rect(x, y, w, h, z, fill)
            rect_index = rect_index + 1
            local pos, size = vector(x, y, z), engine.Vector2(w, h)
            local id = self.rect_ids[rect_index]
            if id then Gui.update_rect(gui, id, pos, size, fill)
            else
                local created = Gui.rect(gui, pos, size, fill)
                if not created then error(PENDING.rect) end
                self.rect_ids[rect_index] = created
            end
        end
        local function label(value, size, x, y, fill)
            text_index = text_index + 1
            local pos = vector(x, y, layer.content)
            local id = self.text_ids[text_index]
            if id then Gui.update_text(gui, id, text.display(value), font_id, size, material_id, pos, fill)
            else
                id = Gui.text(gui, text.display(value), font_id, size, material_id, pos, fill)
                if not id then error(PENDING.text) end
                self.text_ids[text_index] = id
            end
            return id
        end
        local body = colour(255, M.BODY[1], M.BODY[2], M.BODY[3])
        local gold, slate = colour(255, 255, 185, 0), colour(255, M.SLATE[1], M.SLATE[2], M.SLATE[3])
        local x, y, w, h = place.x, place.y, place.w, place.h
        local b, i = M.BORDER * s, M.INSET * s
        rect(x, y, w, h, layer.shade, colour(204, 0, 0, 0))
        rect(x + i, y + i, w - 2 * i, h - 2 * i, layer.body, body)
        rect(x, y + h - b, w, b, layer.border, gold)
        rect(x, y, w, b, layer.border, gold)
        rect(x, y, b, h, layer.border, gold)
        rect(x + w - b, y, b, h, layer.border, gold)
        local top = y + h - (M.BORDER + M.INSET + M.EDGE) * s
        local cx, cw = x + M.PAD * s, w - 2 * M.PAD * s
        local previous = self.scroll
        self.scroll = nil
        for _, item in ipairs(plan.items) do
            if item.kind == 'text' then
                label(item.text, item.size, cx + item.x, top - item.d, palette[item.role]())
            elseif item.kind == 'scroll' then
                -- Carets are measured once per plan, per character. The same
                -- headline keeps its place in the cycle when the panel moves.
                item.bounds = item.bounds or text.boundaries(item.text)
                assert(#item.bounds <= 1024, 'Headline too long')
                item.edges = item.edges or carets(item.text, item.bounds, font_id, item.size)
                local same = previous and previous.text == item.text and previous.size == item.size
                local m = {text=item.text, bounds=item.bounds, edges=item.edges, size=item.size, x=cx,
                    y=top - item.d, width=cw, margin=(M.PAD - M.INSET) * s, travel=item.travel, scale=s,
                    time=same and previous.time or 0, windows=same and previous.windows or {}}
                local value, at = M.advance(m)
                m.id = label(value, item.size, at, m.y, palette.body())
                -- Panel-coloured masks over the side padding hide glyphs
                -- entering or leaving the text column.
                local line_y, line_h = m.y - item.size * 0.35, item.size * 1.5
                rect(x + i, line_y, cx - (x + i), line_h, layer.mask, body)
                rect(cx + cw, line_y, (x + w - i) - (cx + cw), line_h, layer.mask, body)
                self.scroll = m
            elseif item.kind == 'rule' then
                rect(cx, top - item.d, cw, item.h, layer.rule, slate)
            else
                -- Whole-pixel ticks: every tick and gap renders the same width.
                local tick, gap = M.tick_pixels(s)
                local left, bottom = math.floor(cx + item.x + 0.5), math.floor(top - item.d + 0.5)
                local tall = math.max(1, math.floor(item.h + 0.5))
                for t = 1, M.TICKS do
                    rect(left + (t - 1) * (tick + gap), bottom, tick, tall, layer.content,
                        t <= item.ticks and palette.body() or slate)
                end
            end
        end
        -- Clear primitives a longer report used.
        for index = rect_index + 1, #self.rect_ids do
            Gui.update_rect(gui, self.rect_ids[index], vector(0, 0, 0), engine.Vector2(0, 0), body)
        end
        for index = text_index + 1, #self.text_ids do
            Gui.update_text(gui, self.text_ids[index], '', font_id, M.CAPTION * s, material_id, vector(0, 0, 0), body)
        end
    end
    function self:show(model, dt, anchor)
        if not prepare(anchor) then return false end
        local width, height = Gui.resolution()
        -- Unchanged report, geometry and font: only a long headline moves.
        local g = self.geometry
        if g and model.signature == self.signature and anchor.x == g.ax and anchor.y == g.ay
            and anchor.w == g.aw and anchor.h == g.ah and anchor.scale == g.as and width == g.rw and height == g.rh then
            if self.scroll then scroll(dt) end
            return true
        end
        local s = anchor.scale
        if not (width >= 640 and height >= 480 and s > 0) then error(PENDING.native) end
        local font_id = engine.IdString64.from_hex(anchor.font)
        local material_id = engine.IdString64.from_hex(anchor.material)
        local content_w = anchor.w - 2 * M.PAD * s
        local below = planned(model, font_id, content_w, M.below_limit(anchor), s, false)
        local side = not below and planned(model, font_id, content_w, M.side_limit(anchor, height), s, true)
        local place, plan = M.place(anchor, width, height, below, side)
        draw(plan, place, anchor, font_id, material_id)
        self.model, self.signature = model, model.signature
        self.geometry = {ax=anchor.x, ay=anchor.y, aw=anchor.w, ah=anchor.h, as=anchor.scale,
            rw=width, rh=height, place=place, plan=plan}
        return true
    end
    -- Pending reports keep the panel and captions (in the language they were
    -- drawn in) without any enemy text. The pending model is made once, from
    -- the report drawn before it; while it is drawn, later pending frames
    -- pass it again, so they allocate nothing.
    function self:suspend(anchor)
        local model = self.model
        if not self.gui or not model then return false end
        if model.signature ~= 'pending' then
            model = {key=model.key, screen=model.screen, label=model.label, footer=model.footer, signature='pending'}
        end
        return self:show(model, 0, anchor)
    end
    return self
end

return M
