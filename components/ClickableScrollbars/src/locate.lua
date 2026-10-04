-- Which scrollbar is visible and who owns it, and whether that still holds.
local module, cs = ...
local GRID, CAREER, LOADOUT_GRID_OFFSET = cs.GRID, cs.CAREER, cs.LOADOUT_GRID_OFFSET
local OPTIONS_LIST, OPTIONS_PAGES, native_key = cs.OPTIONS_LIST, cs.OPTIONS_PAGES, cs.native_key

-- Resolve the live equipment grid from its screen's registered controller.
-- Ship Armory uses kind 224; the mission loadout picker uses kind 229 and embeds
-- the same grid at a different controller offset in build 25480438.
function module.native_locate(api, memory) -- lint-ok: R10 moved unchanged from the single file; existing debt, not new
    if type(api) ~= 'table' then return nil, 'no reader' end
    memory = memory or module.native_memory(api)
    if not memory then return nil, 'no memory view' end
    local game = api.module('game.dll')
    if not game then return nil, 'game.dll unavailable' end
    local dispatch = api.pointer(api.read(game + 0x3326e68, 8))
    if not dispatch then return nil, 'dispatch table unavailable' end
    local count = memory.read_u32(dispatch + 5740)
    if not count or count < 1 or count > 64 then return nil, 'dispatch bounds changed' end
    -- Snapshot the bounded registry once instead of a system call per row.
    local rows = api.read(dispatch + 5744, count * 16)
    if type(rows) ~= 'string' or #rows ~= count * 16 then return nil, 'dispatch rows unreadable' end

    local has_armory, has_loadout = false, false
    for index = 0, count - 1 do
        local kind = rows:byte(index * 16 + 9)
            + rows:byte(index * 16 + 10) * 256
            + rows:byte(index * 16 + 11) * 65536
            + rows:byte(index * 16 + 12) * 16777216
        if kind == 224 then has_armory = true
        elseif kind == 229 then has_loadout = true end
    end
    local active_kind
    if has_loadout then
        -- The loadout controller can remain registered while a different UI
        -- state is on top. Use the screen stack when readable; captured tests
        -- without that optional anchor still use visible-widget validation.
        local ok, value = pcall(function()
            local stack_owner = api.pointer(api.read(game + 0x347ce28, 8))
            if not stack_owner then return nil end
            local stack = api.read(stack_owner + 0x429c, 24)
            if type(stack) ~= 'string' or #stack < 24 then return nil end
            local function word(offset)
                local a, b, c, d = stack:byte(offset + 1, offset + 4)
                if not d then return nil end
                return a + b * 256 + c * 65536 + d * 16777216
            end
            local depth = word(20)
            if not depth or depth < 1 or depth > 5 then return false end
            local top = word((depth - 1) * 4)
            if top == 5 then return 224 end
            if top == 14 then return 229 end
            return false
        end)
        if ok then active_kind = value end
        if active_kind == false then return nil, 'unsupported UI screen' end
    end

    for index = 0, count - 1 do
        local offset = index * 16
        local kind = rows:byte(offset + 9)
            + rows:byte(offset + 10) * 256
            + rows:byte(offset + 11) * 65536
            + rows:byte(offset + 12) * 16777216
        if (kind == 224 or kind == 229) and (not active_kind or kind == active_kind) then
            local controller = api.pointer(rows, offset)
            if not controller then return nil, 'equipment controller unavailable' end
            local grid_offset = kind == 224 and GRID.offset or LOADOUT_GRID_OFFSET
            local bridge = {api = api, memory = memory, game = game, controller = controller,
                            kind = kind, grid = controller + grid_offset,
                            panel = kind == 224 and controller + CAREER.offset or nil}
            -- Resolved alpha includes parent visibility. The equipment grid
            -- remains allocated behind Career and must never own its gestures.
            if bridge.panel and (memory.read_f32(bridge.panel + CAREER.track + 84) or 0) > 0.95 then
                bridge.route = 'career'
                bridge.bar, bridge.thumb = bridge.panel + CAREER.track, bridge.panel + CAREER.thumb
            elseif (memory.read_f32(bridge.grid + 272 + 84) or 0) > 0.95 then
                bridge.route = 'grid'
                bridge.bar, bridge.thumb = bridge.grid + 272, bridge.grid + 888
            else
                if active_kind then return nil, 'no visible equipment scrollbar' end
                -- A stale/hidden controller may precede the visible owner in
                -- the registry; keep looking before declaring the menu inert.
                bridge = nil
            end
            if bridge then
                bridge.key = native_key(controller) .. ':' .. tostring(kind) .. ':' .. bridge.route
                return bridge
            end
        end
    end
    -- The options pages have no equipment controller registration. Their own
    -- page pointer and active screen ID gate access to each inline list.
    local ok, bindings = pcall(function()
        local owner = api.pointer(api.read(game + 0x347ce28, 8))
        if not owner then return nil end
        local stack = api.read(owner + 0x429c, 24)
        if not stack or #stack ~= 24 then return nil end
        local function word(offset)
            local a, b, c, d = stack:byte(offset + 1, offset + 4)
            return a and d and (a + b * 256 + c * 65536 + d * 16777216)
        end
        local depth = word(20)
        if not depth or depth < 1 or depth > 5 then return nil end
        local screen_id = word((depth - 1) * 4)
        local page = OPTIONS_PAGES[screen_id]
        if not page then return nil end
        local menu = api.pointer(api.read(game + 0x347ce38, 8))
        local screen = menu and api.pointer(api.read(menu + page.menu, 8))
        if not screen or api.read(screen + 12, 1) ~= '\1' then return nil end
        local list = screen + page.list
        local bar, thumb = list + OPTIONS_LIST.bar, list + OPTIONS_LIST.thumb
        if (memory.read_f32(bar + 84) or 0) <= 0.95 then return nil end
        return {api = api, memory = memory, game = game, controller = screen,
                grid = list, bar = bar, thumb = thumb, route = page.route,
                kind = screen_id, key = native_key(screen) .. ':' .. screen_id .. ':' .. page.route}
    end)
    if ok and bindings then return bindings end
    return nil, (has_armory or has_loadout) and 'no visible equipment scrollbar'
        or 'equipment grid not registered'
end

-- native_locate with each of its reads recorded on a tape kept in the bridge.
-- native_locate decides from nothing but those reads, so while every one of
-- them returns the same bytes it would resolve the same owner again. Only the
-- shipped reader records; with another reader the tape stays empty.
function module.native_resolve(api, memory)
    local tape = {n = 0}
    api.tape = tape
    local ok, bridge, reason = pcall(module.native_locate, api, memory)
    api.tape = nil
    if not ok then error(bridge, 0) end
    if bridge then bridge.tape = tape end
    return bridge, reason
end

-- True when every read on the tape returns the bytes it recorded. Unchanged
-- bytes come back as the interned strings on the tape: no allocation.
function module.native_unchanged(api, tape)
    local count = tape and tape.n or 0
    if count == 0 then return false end
    for slot = 3, count * 3, 3 do
        if (api.read(tape[slot - 2], tape[slot - 1]) or false) ~= tape[slot] then return false end
    end
    return true
end

cs.keep_interpreted({module.native_locate, module.native_resolve, module.native_unchanged})
