-- Exercise the public registration contract without a running game.
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
-- Keep automatic assignments away from the user's real settings directory.
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
local assignments = directory .. '/ModBindingsMenu.assignments'
os.remove(assignments)
_G.CowboyBingusModLoader = {log_directory = directory}
dofile(source)

local host = assert(ModBindingsMenu)
assert(host.api == 1 and not host.ready())
local function upvalue(fn, wanted)
    for index = 1, 60 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local state = upvalue(host.register_binding, 'state')
local step = upvalue(update, 'step')
local initialize = upvalue(step, 'initialize')
local dormant = upvalue(initialize, 'DORMANT_ACTIONS')
assert(#dormant == 36 and host.capacity == 36)
assert(dormant[3][3] == 0x6218a8ba and dormant[4][3] == 0xd46660e4)
local seen = {}
for _, entry in ipairs(dormant) do
    local code = entry[1] * 65536 + entry[2]
    assert(not seen[code] and entry[1] >= 9 and entry[1] <= 12 and entry[2] < 97)
    seen[code] = true
end

local function new_session()
    for key in pairs(state.registry) do state.registry[key] = nil end
    for index = #state.order, 1, -1 do state.order[index] = nil end
    state.assignments = nil
end

local registrations = {
    {'map', 0xb46c8096, 1, 12, 1},
    {'external', 0x3ef7f7ad, 2, 12, 0},
    {'armory', 0x19e97f02, 3, 10, 1},
    {'control', 'CONTROL CENTER', 4, 10, 4},
    {'management', 0x2716885e, 5, 10, 8},
    {'arcade', 'STRATAGEM HERO', 6, 10, 14},
    {'hellpod', 0xe89a91ef, 7, 10, 9},
}
for _, row in ipairs(registrations) do
    assert(host.register_binding(row[1], row[2], row[3]))
    local record = state.registry[row[1]]
    assert(record.group == row[4] and record.action == row[5] and record.slot == row[3])
    assert(host.is_down(row[1]) == nil)
end
assert(#state.order == 7)
assert(host.register_binding('external', 0x3ef7f7ad, 2))
assert(not host.register_binding('control', 0x3ef7f7ad, 4))
assert(not host.register_binding('control', 0x3ef7f7ad, 5))
assert(state.registry.control.text == 'CONTROL CENTER')
assert(state.registry.arcade.text == 'STRATAGEM HERO')
assert(host.version == 2)
-- Callers outside a mods/<author>/<entry> resource fall back to MODS.
assert(state.registry.map.category == 'MODS')
print('Seven fixed slot registrations OK')

-- A second v1.1 addon asking for slot 2 gets an automatic action instead.
assert(host.register_binding('other', 0x3ef7f7ad, 2))
assert(state.registry.other.slot == nil and state.registry.other.group == 10
       and state.registry.other.action == 0)
assert(host.register_binding('other', 0x3ef7f7ad, 2))
assert(host.register_binding('new', 'FREE TEXT', 2))
assert(state.registry.new.action == 2)
-- Version 2 automatic registrations (nil or 0) fill the remaining actions.
assert(host.register_binding('auto_a', 'Auto A'))
assert(host.register_binding('auto_b', 'Auto B', 0))
assert(state.registry.auto_a.code == 10 * 65536 + 3)
assert(state.registry.auto_b.code == 10 * 65536 + 5)
assert(host.register_binding('auto_b', 'Auto B'))
assert(not host.register_binding('auto_b', 'Auto B', 3))
assert(not host.register_binding('tab\tid', 'Bad'))
print('Slot 2 overflow and automatic assignment OK')

-- Assignments persist: in a later session the same ids get the same actions,
-- whatever order the addons load in.
local file = assert(io.open(assignments, 'rb'))
local saved = file:read('*a')
file:close()
assert(saved:find('auto_a\t10\t3\n', 1, true) and saved:find('other\t10\t0\n', 1, true))
new_session()
assert(host.register_binding('auto_b', 'Auto B'))
assert(host.register_binding('auto_a', 'Auto A'))
assert(state.registry.auto_a.code == 10 * 65536 + 3)
assert(state.registry.auto_b.code == 10 * 65536 + 5)
-- A new id skips actions reserved for addons absent this session.
assert(host.register_binding('fresh', 'Fresh'))
assert(state.registry.fresh.code == 10 * 65536 + 6)
print('Persistent automatic assignments OK')

-- 29 automatic actions in total; when all are reserved, one held by an addon
-- that did not register this session is reclaimed and its old keys cleared.
local count = 3 -- auto_a, auto_b and fresh are registered in this session.
while host.register_binding('fill_' .. count, 'Fill') do count = count + 1 end
-- 24 unreserved actions, then the two held by the absent 'other' and 'new'.
assert(count == 29)
assert(state.assignments.other == nil and state.assignments.new == nil)
new_session()
for index = 1, 29 do
    assert(host.register_binding('keep_' .. index, 'Keep'))
end
local ok, reason = host.register_binding('overflow', 'Overflow')
assert(not ok and reason:find('36', 1, true))
local cleared = 0
for _ in pairs(state.clear_pending) do cleared = cleared + 1 end
assert(cleared == 29)
print('Capacity limit and reclaiming OK')

-- Version 2 categories: explicit, derived from the addon entry, validated.
new_session()
assert(host.register_binding('a', 0x3ef7f7ad, 1, {category = '  Ship Station Hotkeys '}))
assert(state.registry.a.category == 'SHIP STATION HOTKEYS')
local entry = assert(loadstring(
    'local menu = ... local ok = menu.register_binding("b", 0x3ef7f7ad, 2) return ok',
    '@mods/example/toggle_hud'))
assert(entry(host))
assert(state.registry.b.category == 'TOGGLE HUD')
local wrapped = assert(loadstring(
    'local menu = ... local ok, result = pcall(menu.register_binding, "c", 0x3ef7f7ad, 3) return ok, result',
    '@mods/example/pad_tools'))
local called, registered = wrapped(host)
assert(called and registered and state.registry.c.category == 'PAD TOOLS')
assert(not host.register_binding('d', 0x3ef7f7ad, 4, {category = ''}))
assert(not host.register_binding('d', 0x3ef7f7ad, 4, {category = 12}))
assert(not host.register_binding('d', 0x3ef7f7ad, 4, {category = string.rep('x', 65)}))
assert(not host.register_binding('d', 0x3ef7f7ad, 4, 'category'))
assert(host.register_binding('d', 'Free Text', 4))
assert(state.registry.d.text == 'FREE TEXT')
print('Binding categories and string labels OK')
os.remove(assignments)
