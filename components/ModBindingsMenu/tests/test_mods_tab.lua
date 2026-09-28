-- Drive the MODS tab logic against fake game memory and stubbed native calls.
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
os.remove(directory .. '/ModBindingsMenu.assignments')
_G.CowboyBingusModLoader = {log_directory = directory}
dofile(source)
local ffi = require('ffi')

local host = assert(ModBindingsMenu)
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
local ensure_mods_tab = upvalue(step, 'ensure_mods_tab')
local fill_mods_tab = upvalue(step, 'fill_mods_tab')
local MODS_TITLE_ID = upvalue(ensure_mods_tab, 'MODS_TITLE_ID')

-- A fake game image large enough for the localization and label tables.
local image = ffi.new('uint8_t[?]', 0x3480000)
local screen_memory = ffi.new('uint8_t[?]', 338344 + 2411940)
local base = tonumber(ffi.cast('uint64_t', image))
local screen = tonumber(ffi.cast('uint64_t', screen_memory))
local function put32(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function get32(address) return tonumber(ffi.cast('uint32_t *', address)[0]) end
put32(base + 0x3310210, 0x8d70f451)
put32(base + 0x3310214, 0xf15e5c60)
put32(base + 0x3310218, 0x00847feb)
state.base = base

-- Fake input owner: action state array plus the live and default binding maps
-- (256 records of {code, count, 16 x 20-byte mappings}).
local dormant = upvalue(upvalue(step, 'initialize'), 'DORMANT_ACTIONS')
local owner = ffi.new('uint8_t[?]', 687000)
local live_map = ffi.new('uint8_t[?]', 256 * 328)
local default_map = ffi.new('uint8_t[?]', 256 * 328)
local owner_address = tonumber(ffi.cast('uint64_t', owner))
local function put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
put64(base + 0x347cf18, owner_address)
put64(owner_address + 686800, ffi.cast('uint64_t', live_map))
put32(owner_address + 686808, 256)
put64(owner_address + 686968, ffi.cast('uint64_t', default_map))
put32(owner_address + 686976, 256)
local original_label, record_index = {}, {}
for index, entry in ipairs(dormant) do
    local code = entry[1] * 65536 + entry[2]
    original_label[code] = entry[3]
    record_index[code] = index + 10
    put32(base + 0x26438a0 + (entry[1] * 97 + entry[2]) * 4, entry[3])
    for _, map in ipairs({live_map, default_map}) do
        put32(tonumber(ffi.cast('uint64_t', map)) + (index + 10) * 328, code)
    end
end
local function record(map, group, action)
    return tonumber(ffi.cast('uint64_t', map)) + record_index[group * 65536 + action] * 328
end
function struct_pack_u32(value)
    local cell = ffi.new('uint32_t[1]', value)
    return ffi.string(cell, 4)
end
-- A 20-byte mapping: device in the low nibble; bytes 6-7 are parser padding.
local function mapping(device, key, padding)
    return string.char(device + 0x40, 0xff, 0x00, 0x10) .. string.char(key, 0, padding or 0, 0) ..
           string.rep('\0', 12)
end
local function set_mappings(address, list)
    put32(address + 4, #list)
    for index, blob in ipairs(list) do ffi.copy(ffi.cast('uint8_t *', address + 8 + (index - 1) * 20), blob, 20) end
end
local function get_mappings(address)
    local list = {}
    for index = 0, get32(address + 4) - 1 do
        list[#list + 1] = ffi.string(ffi.cast('uint8_t *', address + 8 + index * 20), 20)
    end
    return list
end

local bar = screen + 1248
local listing = screen + 338344
local calls = {labels = {}, builds = 0, resets = {}}
state.set_tab_labels = function(target, labels, count)
    assert(tonumber(ffi.cast('uint64_t', target)) == bar)
    for index = 0, count - 1 do calls.labels[index + 1] = labels[index] end
    put32(bar + 57448, count)
    for index = 0, 7 do put32(bar + 11004 + 3400 * index, index < count and 1 or 0) end
end
state.build_rows = function(target, rows)
    assert(tonumber(ffi.cast('uint64_t', target)) == listing)
    calls.builds = calls.builds + 1
    local count = get32(listing + 2411928)
    put32(listing + 2411916, count)
    for index = 0, count - 1 do
        local row = listing + 7856 + 24784 * index
        local group, action, header = rows[index * 3], rows[index * 3 + 1], rows[index * 3 + 2]
        put32(row + 24752, header ~= 0 and 4 or 1)
        put32(row + 4264 + 272, header)
        put32(row + 24760, header ~= 0 and 0xffffffff or group * 65536 + action)
    end
end
state.reset_list = function(target, tab) calls.resets[#calls.resets + 1] = tab end

-- Unsupported layouts are left alone.
put32(bar + 57448, 5)
assert(not ensure_mods_tab(screen) and #calls.labels == 0)

-- The native three tabs gain MODS; the current tab keeps its selected state.
put32(bar + 57448, 3)
put32(bar + 57452, 1)
assert(ensure_mods_tab(screen))
assert(#calls.labels == 4 and calls.labels[1] == 0x8d70f451 and calls.labels[3] == 0x00847feb)
assert(calls.labels[4] == MODS_TITLE_ID)
assert(get32(bar + 57448) == 4)
assert(get32(bar + 11004 + 3400) == 3 and screen_memory[1248 + 11021 + 3400] == 1)
assert(get32(bar + 11004) == 1)
assert(state.title_active)
-- Already four tabs: nothing is relabelled again.
calls.labels = {}
assert(ensure_mods_tab(screen) and #calls.labels == 0)

local release_labels = upvalue(step, 'release_labels')
local function slot_text(rva)
    local pointer = ffi.cast('uint64_t *', base + rva)[0]
    if pointer == 0 then return nil end
    return ffi.string(ffi.cast('const char *', pointer))
end
local function header_label(index)
    return get32(listing + 7856 + 24784 * index + 4264 + 272)
end

-- With nothing registered the tab explains itself with one header.
put32(screen + 8, 3)
fill_mods_tab(screen)
assert(calls.builds == 1 and get32(listing + 2411916) == 1)
assert(header_label(0) == 0x77bf158a and slot_text(0x3327800) == 'NO MOD BINDINGS INSTALLED')
release_labels()
assert(slot_text(0x3327800) == nil)
state.layout = nil
calls.builds = 0

-- Registered bindings fill the MODS tab only while it is selected.
assert(host.register_binding('map', 0xb46c8096, 1, {category = 'Ship Station Hotkeys'}))
assert(host.register_binding('external', 'Toggle HUD', 2))
-- A pooled slot the game already filled is skipped.
ffi.cast('uint64_t *', base + 0x3327800)[0] = 1
put32(screen + 8, 0)
fill_mods_tab(screen)
assert(calls.builds == 0)
put32(screen + 8, 3)
fill_mods_tab(screen)
assert(calls.builds == 1 and calls.resets[#calls.resets] == 3)
-- Sections sort by name: MODS (derived fallback) before SHIP STATION HOTKEYS.
assert(get32(listing + 2411916) == 4)
assert(header_label(0) == 0x76ad93e3 and slot_text(0x3327550) == 'MODS')
assert(get32(listing + 7856 + 24784 + 24760) == 12 * 65536 + 0)
assert(header_label(2) == 0x431da596 and slot_text(0x3328238) == 'SHIP STATION HOTKEYS')
assert(get32(listing + 7856 + 3 * 24784 + 24760) == 12 * 65536 + 1)
-- The string row label borrows a pooled ID written to the action label table.
assert(slot_text(0x3328230) == 'TOGGLE HUD')
assert(get32(base + 0x26438a0 + (12 * 97 + 0) * 4) == 0xa9cf13bb)
assert(get32(base + 0x26438a0 + (12 * 97 + 1) * 4) == 0xb46c8096)
assert(MODS_TITLE_ID == 0x781e104c)
-- Rebuilt rows are recognised, so later frames do not rebuild.
fill_mods_tab(screen)
assert(calls.builds == 1)
-- Returning from another tab leaves foreign rows; the MODS tab rebuilds them.
put32(listing + 7856 + 4264 + 272, 0x12345678)
fill_mods_tab(screen)
assert(calls.builds == 2)
-- A new registration while the tab is open adds its section.
assert(host.register_binding('late', 0x3ef7f7ad, 3, {category = 'Arc Tools'}))
fill_mods_tab(screen)
assert(calls.builds == 3 and get32(listing + 2411916) == 6)
assert(slot_text(0x3328248) == 'ARC TOOLS' and header_label(0) == 0xc80d6bd6)
-- Leaving the page returns every borrowed slot and pooled row label.
release_labels()
for _, rva in ipairs({0x3327550, 0x3328230, 0x3328238, 0x3328248}) do
    assert(slot_text(rva) == nil)
end
assert(ffi.cast('uint64_t *', base + 0x3327800)[0] == 1)
assert(get32(base + 0x26438a0 + (12 * 97 + 0) * 4) == original_label[12 * 65536])
print('Native MODS tab relabel, per-mod sections, label pool and rebuild OK')

-- is_down reads the game's evaluated action state, so every trigger type and
-- device works: byte 0 of owner + 808 + 32 * (97 * group + action).
local sweep = upvalue(step, 'sweep_inherited_mappings')
sweep()
assert(host.is_down('map') == false and host.is_down('external') == false)
owner[808 + 32 * (97 * 12 + 1)] = 1
assert(host.is_down('map') == true and host.is_down('external') == false)
owner[808 + 32 * (97 * 12 + 1)] = 0
owner[808 + 32 * (97 * 12 + 0)] = 1
assert(host.is_down('map') == false and host.is_down('external') == true)
assert(host.is_down('unregistered') == nil)
owner[808 + 32 * (97 * 12 + 0)] = 0
print('Native action state drives is_down OK')

-- Inherited developer defaults never fire a mod binding. Slot 1 ships its own
-- keyboard default (Tab) next to the developer mouse and pad mappings.
local KEYBOARD, MOUSE, PAD = 3, 2, 5
local tab, left_click, pad_a = mapping(KEYBOARD, 76), mapping(MOUSE, 1), mapping(PAD, 9)
set_mappings(record(default_map, 12, 1), {pad_a, tab, left_click})
-- The user rebound Open Map to F2 in v1; the saved action kept the extras,
-- whose padding bytes differ from the parsed defaults.
local f2, rebound_click = mapping(KEYBOARD, 60), mapping(MOUSE, 1, 0x7f)
set_mappings(record(live_map, 12, 1), {pad_a, f2, rebound_click})
-- Slot 2 has no shipped default: all of its developer mappings go.
local escape_hold, right_arrow = mapping(KEYBOARD, 1), mapping(KEYBOARD, 77)
set_mappings(record(default_map, 12, 0), {escape_hold, right_arrow})
set_mappings(record(live_map, 12, 0), {right_arrow, escape_hold, mapping(KEYBOARD, 33)})
-- An automatic action being reclaimed is cleared entirely.
set_mappings(record(live_map, 10, 0), {mapping(KEYBOARD, 44)})
state.clear_pending[10 * 65536] = true
sweep()
local kept = get_mappings(record(live_map, 12, 1))
assert(#kept == 1 and kept[1] == f2)
kept = get_mappings(record(live_map, 12, 0))
assert(#kept == 1 and kept[1] == mapping(KEYBOARD, 33))
assert(#get_mappings(record(live_map, 10, 0)) == 0 and not state.clear_pending[10 * 65536])
-- The shipped Tab default itself is kept.
set_mappings(record(live_map, 12, 1), {tab, left_click})
sweep()
kept = get_mappings(record(live_map, 12, 1))
assert(#kept == 1 and kept[1] == tab)
-- RepeatInterval button defaults (v1.2.2 ship stations) become Press, in both
-- places the trigger is stored; axis mappings and other triggers are untouched.
local function blob(flags, key, trigger)
    return struct_pack_u32(flags) .. string.char(key, 0, 0, 0) .. struct_pack_u32(trigger) ..
           string.rep('\0', 8)
end
local repeat_f5 = blob(0xF3A8FF43, 0x74, 8)       -- keyboard button, RepeatInterval
local hold_f6 = blob(0xF3B2FF43, 0x75, 2)         -- keyboard button, Hold
local stick = blob(0x0008FF85, 0x10, 8)           -- pad axis, trigger value 8
set_mappings(record(default_map, 10, 4), {})
set_mappings(record(live_map, 10, 4), {repeat_f5, hold_f6, stick})
sweep()
kept = get_mappings(record(live_map, 10, 4))
assert(#kept == 3 and kept[1] == blob(0xF3A0FF43, 0x74, 0))
assert(kept[2] == hold_f6 and kept[3] == stick)
-- A re-parse or Revert restores the extras: is_down cleans up before trusting
-- the state and reports this frame as not down.
set_mappings(record(live_map, 12, 1), {tab, left_click, pad_a})
owner[808 + 32 * (97 * 12 + 1)] = 1
assert(host.is_down('map') == false)
assert(#get_mappings(record(live_map, 12, 1)) == 1)
assert(host.is_down('map') == true)
put64(base + 0x347cf18, 0)
state.buckets = {}
assert(host.is_down('map') == nil)
print('Inherited developer mappings removed OK')

-- The game can refuse page-protection changes mid-session. Pages that are not
-- currently writable and a failing VirtualProtect must degrade the MODS tab,
-- never leave the previous tab's rows (or raise), and never free a buffer the
-- game can still see.
put64(base + 0x347cf18, owner_address)
state.buckets = {}
local claim_label = upvalue(upvalue(fill_mods_tab, 'mods_layout'), 'claim_label')
local write_memory = upvalue(upvalue(claim_label, 'write_u64'), 'write_memory')
local real_kernel32 = upvalue(write_memory, 'kernel32')
local refuse = false
local fake_kernel32 = setmetatable({
    VirtualQuery = function(address, info, size)
        local found = real_kernel32.VirtualQuery(address, info, size)
        if refuse then info.Protect = 0x02 end -- PAGE_READONLY
        return found
    end,
    VirtualProtect = function(...) if refuse then return 0 end return real_kernel32.VirtualProtect(...) end,
    GetLastError = function() return 5 end,
}, {__index = function(_, key) return real_kernel32[key] end})
for index = 1, 60 do
    local name = debug.getupvalue(write_memory, index)
    if name == 'kernel32' then debug.setupvalue(write_memory, index, fake_kernel32) break end
end
release_labels()
state.layout = nil
refuse = true
put32(screen + 8, 3)
put32(listing + 7856 + 4264 + 272, 0x12345678)
local builds = calls.builds
fill_mods_tab(screen)
assert(calls.builds == builds + 1, 'MODS tab must still be rebuilt')
-- Headers fall back to the MODS title (kept alive for the addon's lifetime);
-- all sections share that single header.
assert(header_label(0) == MODS_TITLE_ID and get32(listing + 2411916) == 4)
for _, rva in ipairs({0x3327550, 0x3328230, 0x3328238, 0x3328248}) do
    assert(slot_text(rva) == nil, 'refused writes must not claim slots')
end
-- A claim whose slot cannot be cleared stays alive.
refuse = false
state.layout = nil
put32(listing + 7856 + 4264 + 272, 0x12345678)
fill_mods_tab(screen)
assert(slot_text(0x3328230) ~= nil)
refuse = true
release_labels()
assert(next(state.claims) ~= nil and slot_text(0x3328230) ~= nil)
refuse = false
release_labels()
assert(next(state.claims) == nil and slot_text(0x3328230) == nil)
print('Refused memory writes degrade safely OK')
os.remove(directory .. '/ModBindingsMenu.assignments')
