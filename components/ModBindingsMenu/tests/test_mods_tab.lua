-- Drive the MODS tab logic against fake game memory and stubbed native calls.
local source = arg[1] or ((arg[0]:match('^(.*[/\\])') or '') .. '../src/mod_bindings_menu.lua')
local directory = assert(os.getenv('TEMP') or os.getenv('TMP'))
-- The assignments file, its backup and an interrupted save's temporary file.
local function remove_assignments()
    for _, suffix in ipairs({'', '.bak', '.tmp'}) do os.remove(directory .. '/ModBindingsMenu.assignments' .. suffix) end
end
remove_assignments()
_G.CowboyBingusModLoader = {log_directory = directory}
-- The build puts the text module and the locales ahead of the main file as
-- the local mbm_text; here it is a global.
local root = source:match('^(.*)[/\\]src[/\\][^/\\]+$') or '.'
local Text = dofile(root .. '/src/bingus_text.lua')
_G.BingusTranslations = nil
Text.registry().steam_language = 'en'
_G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
-- The other source files: the build places them ahead of the main file as
-- the functions in the local mbm_files; here mbm_files loads src/<name>.lua.
_G.mbm_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})
-- The game's update, which the menu's guard wraps.
_G.update = function() end
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
-- The function value of an upvalue named wanted, searched from fn through
-- every function it reaches.
local function internal(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return nil end
    seen[fn] = true
    local nested = {}
    for index = 1, 60 do
        local name, value = debug.getupvalue(fn, index)
        if name == nil then break end
        if name == wanted then return value end
        if type(value) == 'function' then nested[#nested + 1] = value end
    end
    for _, inner in ipairs(nested) do
        local value = internal(inner, wanted, seen)
        if value ~= nil then return value end
    end
    return nil
end
local state = upvalue(host.register_binding, 'state')
local step = upvalue(update, 'step')
local ensure_mods_tab = internal(step, 'ensure_mods_tab')
local fill_mods_tab = internal(step, 'fill_mods_tab')
-- One binding-page frame (dt 0): the selected tab is read once and passed on.
local page_frame = internal(step, 'page_frame')
local function show_page(screen) page_frame(screen, 0) end
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

local release_labels = internal(step, 'release_labels')
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
show_page(screen)
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
show_page(screen)
assert(calls.builds == 0)
put32(screen + 8, 3)
show_page(screen)
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
show_page(screen)
assert(calls.builds == 1)
-- Returning from another tab leaves foreign rows; the MODS tab rebuilds them.
put32(screen + 8, 0)
show_page(screen)
put32(listing + 7856 + 4264 + 272, 0x12345678)
put32(screen + 8, 3)
show_page(screen)
assert(calls.builds == 2)
-- A new registration while the tab is open adds its section.
assert(host.register_binding('late', 0x3ef7f7ad, 3, {category = 'Arc Tools'}))
show_page(screen)
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

-- The first sweep of an action clears its inherited developer defaults, once:
-- they must never fire a mod binding. Slot 1 ships its own keyboard default
-- (Tab) next to the developer mouse and pad mappings.
local sweep = internal(step, 'sweep_bindings')
local KEYBOARD, MOUSE, PAD = 3, 2, 5
local tab, left_click, pad_a = mapping(KEYBOARD, 76), mapping(MOUSE, 1), mapping(PAD, 9)
set_mappings(record(default_map, 12, 1), {pad_a, tab, left_click})
-- The user rebound Open Map to F2 in v1; the saved action kept the extras,
-- whose padding bytes differ from the parsed defaults.
local f2, rebound_click = mapping(KEYBOARD, 60), mapping(MOUSE, 1, 0x7f)
set_mappings(record(live_map, 12, 1), {pad_a, f2, rebound_click})
-- Slot 2 has no default of Mod Bindings Menu's own: all of its developer mappings go.
local escape_hold, right_arrow = mapping(KEYBOARD, 1), mapping(KEYBOARD, 77)
set_mappings(record(default_map, 12, 0), {escape_hold, right_arrow})
set_mappings(record(live_map, 12, 0), {right_arrow, escape_hold, mapping(KEYBOARD, 33)})
-- RepeatInterval button defaults (v1.2.2 ship stations) become Press, in both
-- places the trigger is stored; axis mappings and other triggers are untouched.
local function blob(flags, key, trigger)
    return struct_pack_u32(flags) .. string.char(key, 0, 0, 0) .. struct_pack_u32(trigger) ..
           string.rep('\0', 8)
end
local repeat_f5 = blob(0xF3A8FF43, 0x74, 8)       -- keyboard button, RepeatInterval
local hold_f6 = blob(0xF3B2FF43, 0x75, 2)         -- keyboard button, Hold
local stick = blob(0x0008FF85, 0x10, 8)           -- pad axis, trigger value 8
set_mappings(record(default_map, 10, 1), {})
set_mappings(record(live_map, 10, 1), {repeat_f5, hold_f6, stick})
sweep()
local kept = get_mappings(record(live_map, 12, 1))
assert(#kept == 1 and kept[1] == f2)
kept = get_mappings(record(live_map, 12, 0))
assert(#kept == 1 and kept[1] == mapping(KEYBOARD, 33))
kept = get_mappings(record(live_map, 10, 1))
assert(#kept == 3 and kept[1] == blob(0xF3A0FF43, 0x74, 0))
assert(kept[2] == hold_f6 and kept[3] == stick)
-- Afterwards a mapping the player chose stays, even one equal to a developer
-- default: left click next to Tab on slot 1.
set_mappings(record(live_map, 12, 1), {tab, left_click})
sweep()
kept = get_mappings(record(live_map, 12, 1))
assert(#kept == 2 and kept[1] == tab and kept[2] == left_click)
print('Inherited developer mappings cleared once, the player\'s mappings kept OK')

-- is_down reads the game's evaluated action state, so every trigger type and
-- device works: byte 0 of owner + 808 + 32 * (97 * group + action).
assert(host.is_down('map') == false and host.is_down('external') == false)
owner[808 + 32 * (97 * 12 + 1)] = 1
assert(host.is_down('map') == true and host.is_down('external') == false)
owner[808 + 32 * (97 * 12 + 1)] = 0
owner[808 + 32 * (97 * 12 + 0)] = 1
assert(host.is_down('map') == false and host.is_down('external') == true)
assert(host.is_down('unregistered') == nil)
owner[808 + 32 * (97 * 12 + 0)] = 0
print('Native action state drives is_down OK')

-- A re-parse or a Revert restores the shipped defaults: is_down has them swept
-- away before it trusts the state, and reports this frame as not down.
set_mappings(record(live_map, 12, 1), {pad_a, tab, left_click})
owner[808 + 32 * (97 * 12 + 1)] = 1
assert(host.is_down('map') == false)
kept = get_mappings(record(live_map, 12, 1))
assert(#kept == 1 and kept[1] == tab)
assert(host.is_down('map') == true)
put64(base + 0x347cf18, 0)
state.buckets = {}
assert(host.is_down('map') == nil)
print('Restored developer defaults removed before is_down answers OK')

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
    MBM_VirtualQuery = function(address, info, size)
        local found = real_kernel32.MBM_VirtualQuery(address, info, size)
        if refuse then info.Protect = 0x02 end -- PAGE_READONLY
        return found
    end,
    MBM_VirtualProtect = function(...) if refuse then return 0 end return real_kernel32.MBM_VirtualProtect(...) end,
    MBM_GetLastError = function() return 5 end,
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
show_page(screen)
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
show_page(screen)
assert(slot_text(0x3328230) ~= nil)
refuse = true
release_labels()
assert(next(state.claims) ~= nil and slot_text(0x3328230) ~= nil)
refuse = false
release_labels()
assert(next(state.claims) == nil and slot_text(0x3328230) == nil)
print('Refused memory writes degrade safely OK')
remove_assignments()

-- Translations (API version 3): limits count characters, names are
-- upper-cased beyond a-z, and texts given as functions, MBM's own texts and
-- the MODS title follow the language when a binding page opens.
do
    local translation = upvalue(host.register_binding, 'translation')
    local function cjk(count, from)
        local parts = {}
        for index = 1, count do parts[index] = Text.encode(0x4E00 + (from or 0) + index) end
        return table.concat(parts)
    end
    -- 100 CJK characters (300 bytes) fit the 127-character label limit; 128 do not.
    assert(host.register_binding('zh.long', cjk(100), nil, {category = cjk(20, 50)}))
    assert(not host.register_binding('zh.too_long', cjk(128)))
    assert(not host.register_binding('zh.bad', 'bad \255 bytes'), 'invalid UTF-8')
    assert(host.register_binding('ru.jump', 'x', nil, {category = '\208\191\209\128\209\139\208\182\208\186\208\184'}))
    assert(state.registry['ru.jump'].category == '\208\159\208\160\208\171\208\150\208\154\208\152', 'Cyrillic upper case')
    -- Texts as functions.
    local language = 'en'
    local words = {en = {label = 'Toggle Map', category = 'Map Tools'},
                   zh = {label = cjk(4, 100), category = cjk(3, 200)}}
    local function word(field) return function() return words[language][field] end end
    assert(host.register_binding('fn.map', word('label'), nil, {category = word('category')}))
    assert(host.register_binding('fn.map', word('label'), nil, {category = word('category')}), 'new closures: same binding')
    local record = state.registry['fn.map']
    assert(record.text == 'TOGGLE MAP' and record.category == 'MAP TOOLS')
    -- The language changes; a pack translates MBM's own texts.
    language = 'zh'
    Text.register({language = 'zh-Hans', name = 'test', mods = {mod_bindings_menu = {
        ['tab.mods'] = cjk(2, 300), ['section.none'] = cjk(8, 400)}}})
    Text.registry().game_language = 'zh-Hans'
    -- While a game slot points at the MODS title buffer, the buffer stays.
    state.title_active = true
    local kept = state.mods_text
    local revision = state.revision
    translation.refresh()
    assert(state.mods_text == kept and record.text == words.zh.label and record.category == words.zh.category)
    assert(state.empty_text == cjk(8, 400) and state.revision > revision, 'the layout is rebuilt')
    assert(host.revision == state.revision, 'other mods see the new revision')
    -- Once the slot is released, the next page opening swaps in a buffer of the new title.
    state.title_active = false
    translation.refresh()
    assert(state.mods_text ~= kept and ffi.string(state.mods_text) == cjk(2, 300))
    assert(state.titles[#state.titles] == kept, 'the old buffer stays referenced')
    -- The rebuilt MODS tab shows the translated section and binding names.
    state.layout = nil
    put32(screen + 8, 3)
    put32(listing + 7856 + 4264 + 272, 0x12345678)
    show_page(screen)
    local texts = {}
    for _, claim in pairs(state.claims) do texts[ffi.string(claim.buffer)] = true end
    assert(texts[words.zh.label] and texts[words.zh.category], 'translated rows and headers')
    release_labels()
    -- A text function that fails keeps the text shown before.
    words.zh.label = nil
    translation.refresh()
    assert(record.text == cjk(4, 100))
end
print('Translations: character limits, upper case in every script, function texts, own texts and the MODS title '
      .. 'buffer refreshed when a page opens OK')
remove_assignments()

-- Step errors and the update chain, through Bingus Shared Runtime's guard, on
-- fresh instances chained after a previous update. The step's errors come in
-- bursts, which 3600 error-free frames end; each burst logs one line, and the
-- 8th error of a burst stops the step for the session (no traceback is ever
-- built; no log line, read or allocation per frame after): the MODS title and
-- the borrowed text slots go back to the game as when a binding page closes, or
-- stay borrowed while a page is open. An error in the update below reaches the
-- caller unchanged and pauses the menu on the next frame: the page's own state
-- resets (a page that was open counts as visited for the next sweep), the title
-- and the slots go back unless a page is open, and the binding maps are not
-- touched; the step resumes once the update below has returned on 60 frames in
-- a row, and the 8th such error in a burst stops it. The game's shutdown runs
-- the same release and keeps the first failure. Every argument and every return
-- value pass through to the previous update, error or not.
do
    local function set_upvalue(fn, wanted, value)
        for index = 1, 60 do
            local name = debug.getupvalue(fn, index)
            if name == wanted then debug.setupvalue(fn, index, value); return end
            if name == nil then break end
        end
        error('missing upvalue ' .. wanted)
    end
    local lines, tracebacks, recording, passed = {}, 0, true, {}
    local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
    local real_traceback = debug.traceback
    debug.traceback = function(...) tracebacks = tracebacks + 1; return real_traceback(...) end
    -- The update below: returns 1, nil, 3, or raises while below.fail is set.
    local below, shutdowns = {fail = false}, 0
    local function previous(...)
        if recording then passed[#passed + 1] = {n = select('#', ...), ...} end
        if below.fail then error('the update below failed', 0) end
        return 1, nil, 3
    end
    local function previous_shutdown() shutdowns = shutdowns + 1 end
    local function pack(...) return {n = select('#', ...), ...} end
    local function count(text, from)
        local found = 0
        for index = from, #lines do
            if lines[index]:find(text, 1, true) then found = found + 1 end
        end
        return found
    end
    local function frame(wrapper)
        local results = pack(wrapper(0.016, 'marker', nil))
        local got = passed[#passed]
        assert(got.n == 3 and got[1] == 0.016 and got[2] == 'marker', 'arguments pass through')
        assert(results.n == 3 and results[1] == 1 and results[2] == nil and results[3] == 3, 'results pass through')
    end
    -- A frame whose update below raises: the error reaches the caller unchanged.
    local function failing_frame(wrapper)
        below.fail = true
        local ok, problem = pcall(wrapper, 0.016, 'marker', nil)
        below.fail = false
        assert(not ok and problem == 'the update below failed', 'the error below passes unchanged')
        local got = passed[#passed]
        assert(got.n == 3 and got[1] == 0.016 and got[2] == 'marker', 'arguments pass through')
    end
    -- The bindings page (screen type 26) on top of the UI stack, or another screen.
    local ui_memory, menu_memory = ffi.new('uint8_t[?]', 0x429c + 24), ffi.new('uint8_t[?]', 216)
    local ui = tonumber(ffi.cast('uint64_t', ui_memory))
    put64(base + 0x347ce28, ui)
    put64(base + 0x347ce38, tonumber(ffi.cast('uint64_t', menu_memory)))
    put64(tonumber(ffi.cast('uint64_t', menu_memory)) + 208, screen)
    local function page(open)
        put32(ui + 0x429c + 20, 1)
        put32(ui + 0x429c, open and 26 or 1)
    end
    local title_slot = ffi.cast('uint64_t *', base + 0x3328420)
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
    -- A fresh instance on the simulated game, its native list calls stubbed
    -- as above, with one text binding under its own section. Its first frame
    -- opens the MODS tab: the tab bar has the three native tabs again.
    local function fresh(id)
        _G.ModBindingsMenu, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
        Text.registry().steam_language = 'en'
        _G.update, _G.shutdown = previous, previous_shutdown
        dofile(source)
        local menu = ModBindingsMenu
        local st = upvalue(menu.register_binding, 'state')
        st.initialized, st.base = true, base
        st.set_tab_labels, st.build_rows, st.reset_list = state.set_tab_labels, state.build_rows, state.reset_list
        assert(menu.register_binding(id, 'Stop Text', nil, {category = 'Stopper'}))
        title_slot[0] = 0
        put32(bar + 57448, 3); put32(bar + 57452, 1); put32(screen + 8, 3)
        page(true)
        return menu, st, update, BingusRuntime.statuses.ModBindingsMenu, shutdown
    end
    -- What the open page borrowed: the title slot and each claimed slot, with
    -- the address of the buffer each points at.
    local function borrowed(st)
        local slots = {}
        for text, claim in pairs(st.claims) do
            slots[#slots + 1] = {pointer = ffi.cast('uint64_t *', claim.address), buffer = ffi.cast('uint64_t', claim.buffer),
                                 text = text}
        end
        assert(#slots == 2 and st.title_active and title_slot[0] == ffi.cast('uint64_t', st.mods_text))
        for _, slot in ipairs(slots) do assert(slot.pointer[0] == slot.buffer) end
        return slots
    end
    local function released(st, slots)
        assert(not st.title_active and title_slot[0] == 0 and next(st.claims) == nil, 'title and claims released')
        for _, slot in ipairs(slots) do assert(slot.pointer[0] == 0, slot.text .. ' slot released') end
    end
    -- The step's calls, through a scripted step that raises on the calls failing names.
    local function scripted(wrapper, failing)
        local real_step, script = upvalue(wrapper, 'step'), {calls = 0}
        set_upvalue(wrapper, 'step', function(dt)
            script.calls = script.calls + 1
            if failing[script.calls] then error('scripted failure at call ' .. script.calls .. '.', 0) end
            return real_step(dt)
        end)
        return script, real_step
    end

    -- A step that fails a few times and recovers keeps running; errors fewer
    -- than 3600 error-free frames apart belong to one burst, whose 8th error
    -- stops the step. The page closes before it: the title and every borrowed
    -- slot go back.
    local menu6, st6, update6, status6 = fresh('stop.released')
    local failing = {[2] = true, [3] = true, [4] = true}
    local script6, real_step = scripted(update6, failing)
    local from = #lines + 1
    for _ = 1, 6 do frame(update6) end
    assert(script6.calls == 6 and status6.errors == 3 and status6.state == 'running', 'a step that recovers keeps running')
    assert(count('ModBindingsMenu error: ', from) == 1 and count('stopped', from) == 0, 'one log line per burst')
    local record6 = st6.registry['stop.released']
    local label = base + 0x26438a0 + (record6.group * 97 + record6.action) * 4
    local slots = borrowed(st6)
    assert(get32(label) ~= original_label[record6.code], 'the row borrowed a label')
    page(false)
    for call = 7, 11 do failing[call] = true end
    local stop_lines
    for index = 1, 10 do
        frame(update6)
        if index == 5 then stop_lines = #lines end
    end
    assert(script6.calls == 11 and status6.errors == 8 and tracebacks == 0, 'the 8th error of a burst stops the step')
    assert(#lines == stop_lines and count('ModBindingsMenu error: ', from) == 1 and count('stopped', from) == 1)
    assert(lines[stop_lines] == 'ModBindingsMenu stopped: stopped after 8 errors: scripted failure at call 2.\n',
           lines[stop_lines])
    assert(status6.state == 'stopped: stopped after 8 errors: scripted failure at call 2.')
    released(st6, slots)
    assert(get32(label) == original_label[record6.code], 'the row label is restored')
    -- The API keeps working.
    assert(menu6.register_binding('stop.later', 'Later') and menu6.ready())
    assert(menu6.is_down('stop.released') ~= nil)
    -- A stopped frame only passes on: no read, no log line, no allocation
    -- (interpreted, so that compiled-trace allocation sinking cannot hide garbage).
    stop_lines = #lines
    local read6 = internal(real_step, 'read')
    local real_kernel = upvalue(read6, 'kernel32')
    local reads = 0
    set_upvalue(read6, 'kernel32', setmetatable({MBM_ReadProcessMemory = function(...)
        reads = reads + 1
        return real_kernel.MBM_ReadProcessMemory(...)
    end, MBM_read_at = function(...)
        reads = reads + 1
        return real_kernel.MBM_read_at(...)
    end}, {__index = real_kernel}))
    recording = false
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 200 do update6(0.016, 'marker') end
    local garbage = collectgarbage('count') - before
    collectgarbage('restart')
    jit.on()
    recording = true
    set_upvalue(read6, 'kernel32', real_kernel)
    assert(reads == 0, 'stopped frames read: ' .. reads)
    assert(garbage == 0, string.format('stopped frames allocated %.2f KB', garbage))
    assert(script6.calls == 11 and tracebacks == 0 and #lines == stop_lines)

    -- A step that always raises runs 8 times. The page is still open, so the
    -- title and the borrowed slots stay borrowed, their buffers with them.
    local menu7, st7, update7, status7 = fresh('stop.kept')
    frame(update7)
    slots = borrowed(st7)
    local always = setmetatable({}, {__index = function() return true end})
    local script7 = scripted(update7, always)
    from = #lines + 1
    for index = 1, 20 do
        frame(update7)
        if index == 8 then stop_lines = #lines end
    end
    assert(script7.calls == 8 and status7.errors == 8 and tracebacks == 0, 'the step stops after its 8th error')
    assert(#lines == stop_lines and count('ModBindingsMenu error: ', from) == 1 and count('stopped', from) == 1)
    -- The stop line comes first, then the release's own line.
    assert(lines[stop_lines - 1] == 'ModBindingsMenu stopped: stopped after 8 errors: scripted failure at call 1.\n',
           'the stop line names the first error')
    assert(lines[stop_lines] == 'A binding page is open; its borrowed text slots stay borrowed.\n')
    borrowed(st7)
    assert(menu7.register_binding('stop.later', 'Later'))
    page(false)

    -- 3600 error-free frames (about a minute at 60 FPS) end a burst, so errors
    -- far apart never add up to a stop; each burst logs one line. 3599 do not.
    local _, _, update8, status8 = fresh('stop.burst')
    page(false)
    local failing8 = {}
    local script8 = scripted(update8, failing8)
    local frame8 = 0
    local function run(frames, fail)
        for _ = 1, frames do
            frame8 = frame8 + 1
            failing8[frame8] = fail
            update8(0.016)
        end
    end
    recording, from = false, #lines + 1
    run(7, true)
    assert(status8.errors == 7 and count('ModBindingsMenu error: ', from) == 1, 'a burst of 7 errors, one log line')
    run(3600, false)
    assert(status8.errors == 0, '3600 error-free frames end the burst')
    run(7, true)
    assert(status8.errors == 7 and count('ModBindingsMenu error: ', from) == 2 and count('stopped', from) == 0,
           'a second burst logs its own line and does not add to the first')
    run(3599, false)
    run(1, true)
    assert(status8.errors == 8 and script8.calls == 7 + 3600 + 7 + 3599 + 1, '3599 error-free frames do not end a burst')
    assert(count('stopped after 8 errors', from) == 1 and count('ModBindingsMenu error: ', from) == 2)
    assert(lines[#lines]:find('stopped after 8 errors', 1, true) and lines[#lines]:find('at call 3608.', 1, true),
           'the stop line names the first error of its burst')
    run(5, false)
    assert(script8.calls == 7 + 3600 + 7 + 3599 + 1, 'the step stays stopped')
    recording = true

    -- An error in the update below while a binding page is open, after the
    -- player set the binding there to a single key equal to its developer
    -- default (numpad 1). The next frame pauses the menu: the page counts as
    -- visited, its state resets, the slots stay borrowed (the page may still
    -- show them) and no binding map changes. The page closes during the pause;
    -- the step skips 60 frames, then resumes, releases what the page borrowed and
    -- sweeps: the player's choice stays, as after any page (without the visit it
    -- would read as a restored default and go).
    local menu9, st9, update9, status9 = fresh('pause.page')
    local script9 = scripted(update9, {})
    local record9 = st9.registry['pause.page']
    local numpad_1 = mapping(KEYBOARD, 79)
    local mapping_address = record(live_map, record9.group, record9.action)
    set_mappings(record(default_map, record9.group, record9.action), {numpad_1})
    set_mappings(mapping_address, {numpad_1})
    -- The first sweep, with the page closed, clears the inherited default.
    page(false)
    st9.sweep_timer = 0
    frame(update9)
    assert(#get_mappings(mapping_address) == 0, 'the first sweep clears the developer default')
    page(true)
    frame(update9)
    slots = borrowed(st9)
    set_mappings(mapping_address, {numpad_1})
    frame(update9)
    assert(st9.page_open and not st9.page_visited, 'the page is open')
    local maps_before = ffi.string(live_map, 256 * 328)
    from = #lines + 1
    failing_frame(update9)
    local calls = script9.calls
    frame(update9)
    assert(status9.state == 'paused: the previous update failed' and status9.pauses == 1, status9.state)
    assert(script9.calls == calls, 'a paused frame runs no step')
    assert(not st9.page_open and st9.page_visited and st9.layout == nil and st9.last_tab == nil, 'the page state resets')
    assert(count('ModBindingsMenu paused: the previous update failed', from) == 1)
    assert(count('A binding page is open; its borrowed text slots stay borrowed.', from) == 1)
    borrowed(st9)
    assert(ffi.string(live_map, 256 * 328) == maps_before, 'a pause touches no binding map')
    page(false)
    -- No allocation per paused frame (interpreted).
    recording = false
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')
    before = collectgarbage('count')
    for _ = 1, 58 do update9(0.016) end
    garbage = (collectgarbage('count') - before) * 1024
    collectgarbage('restart')
    jit.on()
    recording = true
    assert(garbage == 0, string.format('paused frames allocated %d bytes', garbage))
    assert(script9.calls == calls and status9.state ~= 'running', 'paused for 59 frames')
    frame(update9)
    assert(script9.calls == calls and count('resumed', from) == 0, 'paused for 60 frames')
    st9.sweep_timer = 0
    frame(update9)
    assert(script9.calls == calls + 1 and status9.state == 'running', 'the step resumes on the 61st frame')
    assert(count('ModBindingsMenu resumed after 60 clean frames', from) == 1)
    released(st9, slots)
    assert(#get_mappings(mapping_address) == 1 and get_mappings(mapping_address)[1] == numpad_1,
           'the player\'s choice on the page stays')
    assert(count('Kept the single mapping chosen for pause.page on a binding page', from) == 1)
    assert(status9.errors == 0 and status9.lower_errors == 1)
    assert(menu9.register_binding('pause.later', 'Later'))

    -- Errors below further apart than 60 frames each pause and resume; the 8th
    -- of a burst stops the menu (the page closed: everything goes back). The
    -- game's shutdown then keeps the first failure and calls the shutdown below.
    local _, st10, update10, status10, shutdown10 = fresh('pause.burst')
    frame(update10)
    slots = borrowed(st10)
    from = #lines + 1
    -- The first error below comes while the page is open; the page closes
    -- before the next frame, which pauses: the pause gives back what the page
    -- borrowed (the step, which would, does not run).
    failing_frame(update10)
    page(false)
    frame(update10)
    assert(status10.state == 'paused: the previous update failed')
    released(st10, slots)
    for _ = 1, 60 do frame(update10) end
    assert(status10.state == 'running' and status10.pauses == 1, 'pause 1 resumed')
    for burst = 2, 7 do
        failing_frame(update10)
        for _ = 1, 61 do frame(update10) end
        assert(status10.state == 'running' and status10.pauses == burst, 'pause ' .. burst .. ' resumed')
    end
    failing_frame(update10)
    frame(update10)
    assert(status10.state == 'stopped: stopped after 8 failed updates below this mod', status10.state)
    assert(count('ModBindingsMenu paused', from) == 7 and count('ModBindingsMenu resumed', from) == 7)
    assert(lines[#lines] == 'ModBindingsMenu stopped: stopped after 8 failed updates below this mod\n', lines[#lines])
    assert(shutdowns == 0)
    shutdown10('closing')
    assert(shutdowns == 1 and status10.state == 'stopped after: stopped after 8 failed updates below this mod')
    -- A running menu at shutdown: its step stops, what a page borrowed goes back.
    local _, st11, update11, status11, shutdown11 = fresh('shutdown')
    frame(update11)
    slots = borrowed(st11)
    page(false)
    shutdown11()
    assert(shutdowns == 2 and status11.state == 'stopped', status11.state)
    released(st11, slots)
    frame(update11)
    debug.traceback = real_traceback
    _G.CowboyBingusModLoader, _G.shutdown = {log_directory = directory}, nil
end
print('Update errors, through the runtime guard: the 8th error of a burst stops the step (3600 error-free frames end '
      .. 'a burst, one log line per burst) without a traceback, log line, read or allocation per frame after; an '
      .. 'error below pauses the menu (page state reset, a page visit kept for the sweep, the binding maps untouched, '
      .. 'no allocation per paused frame) and it resumes after 60 clean frames; 8 errors below stop it; borrowed '
      .. 'slots go back unless a binding page is open; shutdown keeps the first failure; every argument and return '
      .. 'value pass through OK')
remove_assignments()

-- Per-frame calls, pinned with tests/frame_budget.lua (canonical copy:
-- PerformanceBaseline/frame_budget.lua). A fresh instance on the simulated game
-- holds Ship Station Hotkeys' six bindings; its Windows calls and its native
-- list calls are counted through one api table. In game a ReadProcessMemory
-- costs about 1-2 us and a VirtualQuery about 0.29 ms; VirtualProtect runs only
-- when a page is not writable (never here). Ship Station Hotkeys calls is_down
-- for each of its six bindings on every frame aboard the ship while the game
-- is focused.
do
    local budget = dofile((arg[0]:match('^(.*[/\\])') or './') .. 'frame_budget.lua')
    -- The function holding the upvalue wanted, searched from fn through every
    -- function it reaches, with the upvalue's index and value.
    local function holder(fn, wanted, seen)
        seen = seen or {}
        if seen[fn] then return nil end
        seen[fn] = true
        local nested = {}
        for index = 1, 60 do
            local name, value = debug.getupvalue(fn, index)
            if name == nil then break end
            if name == wanted then return fn, index, value end
            if type(value) == 'function' then nested[#nested + 1] = value end
        end
        for _, inner in ipairs(nested) do
            local found, index, value = holder(inner, wanted, seen)
            if found then return found, index, value end
        end
        return nil
    end
    _G.ModBindingsMenu, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.update = function() end
    dofile(source)
    local menu, wrapper = ModBindingsMenu, update
    local st = upvalue(menu.register_binding, 'state')
    st.initialized, st.base = true, base
    local kernel_holder, kernel_index, real_kernel = holder(wrapper, 'kernel32')
    local api = {
        -- Both prototypes of ReadProcessMemory: the address as a pointer
        -- (read) or as a number (the allocation-free per-frame reads).
        ReadProcessMemory = function(process, address, ...)
            if type(address) == 'number' then return real_kernel.MBM_read_at(process, address, ...) end
            return real_kernel.MBM_ReadProcessMemory(process, address, ...)
        end,
        VirtualQuery = function(...) return real_kernel.MBM_VirtualQuery(...) end,
        VirtualProtect = function(...) return real_kernel.MBM_VirtualProtect(...) end,
        build_rows = state.build_rows, set_tab_labels = state.set_tab_labels, reset_list = state.reset_list,
    }
    local counts = budget.wrap(api)
    -- Mod Bindings Menu's private FFI names, counted under the Windows names.
    local counted = {MBM_read_at = 'ReadProcessMemory', MBM_ReadProcessMemory = 'ReadProcessMemory',
                     MBM_VirtualQuery = 'VirtualQuery', MBM_VirtualProtect = 'VirtualProtect'}
    debug.setupvalue(kernel_holder, kernel_index, setmetatable({}, {__index = function(_, name)
        return counted[name] and api[counted[name]] or real_kernel[name]
    end}))
    st.build_rows = function(...) return api.build_rows(...) end
    st.set_tab_labels = function(...) return api.set_tab_labels(...) end
    st.reset_list = function(...) return api.reset_list(...) end
    -- The bindings page (screen type 26) on top of the UI stack, or another screen.
    local ui_memory, menu_memory = ffi.new('uint8_t[?]', 0x429c + 24), ffi.new('uint8_t[?]', 216)
    local ui = tonumber(ffi.cast('uint64_t', ui_memory))
    put64(base + 0x347ce28, ui)
    put64(base + 0x347ce38, tonumber(ffi.cast('uint64_t', menu_memory)))
    put64(tonumber(ffi.cast('uint64_t', menu_memory)) + 208, screen)
    local function page(open)
        put32(ui + 0x429c + 20, 1)
        put32(ui + 0x429c, open and 26 or 1)
    end
    page(false)
    ffi.cast('uint64_t *', base + 0x3328420)[0] = 0
    local map_state = 808 + 32 * (97 * 12 + 1)
    owner[map_state] = 0
    local SHIP = {{'cowboybingus.galactic_menu', 0xb46c8096, 1}, {'cowboybingus.armory', 0x19e97f02, 3},
                  {'cowboybingus.control_center', 'Control Center', 4},
                  {'cowboybingus.ship_management', 0x2716885e, 5},
                  {'cowboybingus.stratagem_hero', 'Stratagem Hero', 6}, {'cowboybingus.hellpod', 0xe89a91ef, 7}}
    for _, binding in ipairs(SHIP) do
        assert(menu.register_binding(binding[1], binding[2], binding[3], {category = 'Ship Station Hotkeys'}))
    end
    local function frame(label, limits, dt)
        budget.check((budget.frame(counts, wrapper, dt or 0.016)), limits, label)
    end
    local function call(label, limits, fn, ...)
        local calls, result = budget.frame(counts, fn, ...)
        budget.check(calls, limits, label)
        return result
    end
    -- Ship Station Hotkeys' frame: is_down for each of its bindings, in order.
    local function ship_frame()
        local down = 0
        for _, binding in ipairs(SHIP) do
            if menu.is_down(binding[1]) then down = down + 1 end
        end
        return down
    end

    -- Outside a binding page. The session's first sweep indexes both binding
    -- maps (the owner, the map header and 8 reads of 32 records each) and
    -- reads the record of each of the six actions twice and its shipped
    -- defaults once: their first use clears the inherited developer defaults
    -- (was 174 with every dormant action swept, 2424 with a read per bucket).
    frame('first frame: the first sweep', {ReadProcessMemory = 40})
    -- Idle: the binding page check, 2 reads (was 4: the UI state and menu
    -- pointers are read together, so is the screen stack, and the MODS title
    -- slot is read only when the title changes).
    for index = 1, 3 do frame('idle frame ' .. index, {ReadProcessMemory = 2}) end
    -- Every 2 seconds the sweep reads the record of each action a binding
    -- uses, once and whole; nothing changed, so nothing more (was 156: every
    -- dormant action's mappings, a read per mapping).
    frame('sweep frame', {ReadProcessMemory = 8}, 2)
    frame('idle frame after a sweep', {ReadProcessMemory = 2})
    -- is_down: the cached record's code and mapping count in one read, the
    -- input owner and the action's state byte (was 4 reads).
    assert(call('is_down', {ReadProcessMemory = 3}, menu.is_down, SHIP[1][1]) == false)
    assert(call('is_down, unregistered id', {}, menu.is_down, 'unregistered') == nil)
    owner[map_state] = 1
    assert(call('six is_down, Tab down', {ReadProcessMemory = 18}, ship_frame) == 1)
    owner[map_state] = 0
    assert(call('six is_down', {ReadProcessMemory = 18}, ship_frame) == 0)
    -- Ship Station Hotkeys' frame with poll: each record header as is_down
    -- reads it, then the input owner and the six states in one read, from the
    -- lowest action (10:1) to the highest (12:1): 6,209 bytes.
    local ship_ids, polled = {}, {}
    for index, binding in ipairs(SHIP) do ship_ids[index] = binding[1] end
    owner[map_state] = 1
    assert(call('poll of the six, Tab down', {ReadProcessMemory = 8}, menu.poll, ship_ids, polled))
    assert(polled.down[1] == true and polled.pressed[1] == true and polled.down[6] == false)
    owner[map_state] = 0
    assert(call('poll of the six', {ReadProcessMemory = 8}, menu.poll, ship_ids, polled))
    assert(polled.down[1] == false and polled.released[1] == true)
    -- An id that is not registered costs no read; native input not ready, none at all.
    ship_ids[7] = 'unregistered'
    assert(call('poll of the six and an unregistered id', {ReadProcessMemory = 8}, menu.poll, ship_ids, polled))
    assert(polled.down[7] == nil)
    ship_ids[7] = nil
    local build_rows = st.build_rows
    st.build_rows = nil
    assert(call('poll before native input is ready', {}, menu.poll, ship_ids, polled) and polled.down[1] == nil)
    st.build_rows = build_rows

    -- A binding page: the first frame refreshes the texts and adds the MODS tab;
    -- later frames check the page (3 reads), the tab bar and the selected tab,
    -- which is read once per frame (was twice: 12, 6 and 31 below were one more).
    -- The MODS tab's first frame claims its text slots and builds the rows; the
    -- next checks every row (the count and 8 row fields; was every frame, 15
    -- reads); later frames re-read only the row count, and every row again
    -- each 0.5 s.
    put32(bar + 57448, 3); put32(bar + 57452, 1); put32(screen + 8, 0)
    page(true)
    frame('binding page opens on a native tab', {ReadProcessMemory = 11, VirtualQuery = 1, set_tab_labels = 1})
    for index = 1, 2 do frame('binding page on a native tab ' .. index, {ReadProcessMemory = 5}) end
    put32(screen + 8, 3)
    frame('MODS tab, first frame', {ReadProcessMemory = 30, VirtualQuery = 7, build_rows = 1, reset_list = 1})
    frame('MODS tab, rows checked', {ReadProcessMemory = 14})
    for index = 1, 2 do frame('MODS tab ' .. index, {ReadProcessMemory = 6}) end
    frame('MODS tab, rows checked again after 0.5 s', {ReadProcessMemory = 14}, 0.5)
    frame('MODS tab 3', {ReadProcessMemory = 6})
    -- Page frames allocate nothing, interpreted: the page check, the tab bar,
    -- the selected tab and the row checks decode in place (each read allocated
    -- a buffer, a size cell and a string before, about 0.3-1 KB per frame).
    local function page_garbage(frames, dt)
        jit.off()
        jit.flush()
        collectgarbage('collect')
        collectgarbage('stop')
        local start = collectgarbage('count')
        for _ = 1, frames do wrapper(dt) end
        local bytes = (collectgarbage('count') - start) * 1024
        collectgarbage('restart')
        jit.on()
        return bytes
    end
    -- The measured frames advance the sweep timer; it is put back afterwards, so
    -- the page closes below with no sweep due, as before.
    local sweep_timer = st.sweep_timer
    local page_bytes = page_garbage(100, 0.016)
    assert(page_bytes == 0, string.format('MODS tab frames allocated %d bytes', page_bytes))
    page_bytes = page_garbage(20, 0.5)
    assert(page_bytes == 0, string.format('MODS tab frames checking every row allocated %d bytes', page_bytes))
    -- The frame that sees another tab logs it once (a new string); later ones are measured.
    put32(screen + 8, 0)
    frame('native tab selected', {ReadProcessMemory = 5})
    page_bytes = page_garbage(100, 0.016)
    assert(page_bytes == 0, string.format('native tab frames allocated %d bytes', page_bytes))
    put32(screen + 8, 3)
    frame('MODS tab selected again: rows checked', {ReadProcessMemory = 14})
    st.sweep_timer = sweep_timer
    assert(call('six is_down, binding page open', {ReadProcessMemory = 18}, ship_frame) == 0)
    assert(call('poll of the six, binding page open', {ReadProcessMemory = 8}, menu.poll, ship_ids, polled))
    -- Closing the page returns the title, the claimed slots and the row labels.
    page(false)
    frame('binding page closes', {ReadProcessMemory = 8, VirtualQuery = 6})
    for index = 1, 2 do frame('idle frame after the page ' .. index, {ReadProcessMemory = 2}) end

    -- A config re-parse restores the shipped defaults: is_down sweeps first and
    -- reports this frame as not down.
    set_mappings(record(live_map, 12, 1), {pad_a, tab, left_click})
    -- (was 158)
    assert(call('is_down after a re-parse', {ReadProcessMemory = 12}, menu.is_down, SHIP[1][1]) == false)
    assert(#get_mappings(record(live_map, 12, 1)) == 1)
    assert(call('is_down after the sweep', {ReadProcessMemory = 3}, menu.is_down, SHIP[1][1]) == false)
    -- poll sweeps on the same terms (the 12 reads above), then reads the other
    -- five headers, the input owner and the states (six is_down: 12 + 5 x 3).
    set_mappings(record(live_map, 12, 1), {pad_a, tab, left_click})
    assert(call('poll after a re-parse', {ReadProcessMemory = 19}, menu.poll, ship_ids, polled))
    assert(polled.down[1] == false and #get_mappings(record(live_map, 12, 1)) == 1)
    -- A cached record that no longer holds the action (a rebuilt map) is found
    -- again: the same answer, and the cache points at the action's record.
    local map_code = 12 * 65536 + 1
    st.buckets[map_code] = record(live_map, 10, 0)
    owner[map_state] = 1
    assert(menu.is_down(SHIP[1][1]) == true and st.buckets[map_code] == record(live_map, 12, 1))
    owner[map_state] = 0

    -- Idle frames (dt 0: no sweep), Ship Station Hotkeys' six is_down calls and
    -- its poll of the six allocate nothing, interpreted, so that compiled-trace
    -- allocation sinking cannot hide garbage (tests/test_poll.lua checks poll
    -- compiled too).
    owner[map_state] = 1
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')
    local before, down = collectgarbage('count'), 0
    for _ = 1, 100 do
        wrapper(0)
        down = down + ship_frame()
        menu.poll(ship_ids, polled)
        if polled.down[1] then down = down + 1 end
    end
    local garbage = (collectgarbage('count') - before) * 1024
    collectgarbage('restart')
    jit.on()
    owner[map_state] = 0
    assert(down == 200, 'Tab reads as down on every frame, with is_down and with poll')
    assert(garbage == 0, string.format('idle frames, is_down and poll allocated %d bytes', garbage))
    -- Sweep frames (dt 2: one sweep each) with nothing changed allocate nothing
    -- either, interpreted.
    jit.off()
    jit.flush()
    collectgarbage('collect')
    collectgarbage('stop')
    before = collectgarbage('count')
    for _ = 1, 20 do wrapper(2) end
    garbage = (collectgarbage('count') - before) * 1024
    collectgarbage('restart')
    jit.on()
    assert(garbage == 0, string.format('sweep frames allocated %d bytes', garbage))
end
print('Per-frame calls: idle frames, sweeps, is_down, poll, a binding page and the MODS tab within their pinned '
      .. 'budgets, and idle frames, sweeps, is_down and poll without allocation OK')
remove_assignments()
