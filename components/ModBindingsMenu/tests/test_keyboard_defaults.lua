-- The fixed slots' keyboard defaults, added while the game runs instead of by a
-- content/input replacement, against simulated binding maps filled with the
-- game's real lists (build 25480438, read live on 2026-10-18): the stock lists
-- the game parses from its own content/input, and the lists it parsed from the
-- replacement v2.3 and older shipped. Checks: the added lists equal the
-- replacement's byte for byte; lists the player's saved settings set are left
-- alone; a re-parse (device change, settings reset) is undone by the next sweep
-- with no extra read; nothing happens on an unsupported build or while an old
-- replacement is still deployed; players' saved keys survive the switch both
-- ways (a model of the game's own input settings save); the reads are pinned
-- and sweep frames allocate nothing.
local here = arg[0]:match('^(.*[/\\])') or './'
local root = here .. '..'
local source = root .. '/src/mod_bindings_menu.lua'
local ffi = require('ffi')
ffi.cdef [[int mbm_test_CreateDirectoryA(const char *path, void *security) __asm__("CreateDirectoryA");]]
local directory = assert(os.getenv('TEMP') or os.getenv('TMP')) .. '/mbm-test-keyboard-defaults'
ffi.load('kernel32').mbm_test_CreateDirectoryA(directory, nil)
local path = directory .. '/ModBindingsMenu.assignments'
local function remove_files()
    for _, suffix in ipairs({'', '.bak', '.tmp'}) do os.remove(path .. suffix) end
end

-- Simulated game: the image, the input owner and its two binding maps.
local image = ffi.new('uint8_t[?]', 0x3480000)
local base = tonumber(ffi.cast('uint64_t', image))
local function put32(address, value) ffi.cast('uint32_t *', address)[0] = value end
local function get32(address) return tonumber(ffi.cast('uint32_t *', address)[0]) end
local function put64(address, value) ffi.cast('uint64_t *', address)[0] = value end
local owner = ffi.new('uint8_t[?]', 878200)
local live_map, default_map = ffi.new('uint8_t[?]', 256 * 328), ffi.new('uint8_t[?]', 256 * 328)
local owner_address = tonumber(ffi.cast('uint64_t', owner))
put64(base + 0x347cf18, owner_address)
put64(owner_address + 686800, ffi.cast('uint64_t', live_map))
put32(owner_address + 686808, 256)
put64(owner_address + 686968, ffi.cast('uint64_t', default_map))
put32(owner_address + 686976, 256)
-- No binding page: the UI stack's top screen is not 26.
local ui_memory = ffi.new('uint8_t[?]', 0x429c + 24)
put64(base + 0x347ce28, tonumber(ffi.cast('uint64_t', ui_memory)))
put32(tonumber(ffi.cast('uint64_t', ui_memory)) + 0x429c + 20, 1)
put32(tonumber(ffi.cast('uint64_t', ui_memory)) + 0x429c, 1)

local Text = dofile(root .. '/src/bingus_text.lua')
_G.mbm_files = setmetatable({}, {__index = function(files, name)
    local chunk = assert(loadfile(root .. '/src/' .. name .. '.lua'))
    rawset(files, name, chunk)
    return chunk
end})

-- A list of mappings as the game stores it (20 bytes each), from hex.
local function hex(text)
    return (text:gsub('%x%x', function(byte) return string.char(tonumber(byte, 16)) end))
end
local function list(text)
    local out = {}
    for index = 1, #text / 40 do out[index] = hex(text:sub(index * 40 - 39, index * 40)) end
    return out
end
-- The six fixed slots: the stock list (the game's content/input) and the list
-- the replacement file gave (v2.3 and older), each read from the game.
local FIXED = {
    [12 * 65536 + 1] = {
        stock = '41ff60000000000000000000000000000000000042ffc00010000000000000000000000000000000' ..
                '43ffd0003e00000000000000000000000000000044ff000020000000000000000000000000000000',
        replaced = '41ff60000000000000000000000000000000000042ffc00010000000000000000000000000000000' ..
                   '43ff90003a00000000000000000000000000000044ff000020000000000000000000000000000000'},
    [10 * 65536 + 1] = {
        stock = '41ff00000a0000000000000000000000cdcc4c3e42ffa0001b0000000000000000000000cdcc4c3e' ..
                '43ff8006990000000000000000000000cdcc4c3e',
        replaced = '41ff00000a0000000000000000000000cdcc4c3e42ffa0001b0000000000000000000000cdcc4c3e' ..
                   '43ff0007a10000000000000000000000cdcc4c3e'},
    [10 * 65536 + 4] = {
        stock = '41ff8800040000000800000000000000cdcc4c3e42ff0800140000000800000000000000cdcc4c3e' ..
                '43ff7806980000000800000000000000cdcc4c3e',
        replaced = '41ff8800040000000800000000000000cdcc4c3e42ff0800140000000800000000000000cdcc4c3e' ..
                   '43ff4007a50000000000000000000000cdcc4c3e'},
    [10 * 65536 + 8] = {
        stock = '41ffd800090000000800000000000000cdcc4c3e42fff800130000000800000000000000cdcc4c3e' ..
                '43ff98069a0000000800000000000000cdcc4c3e',
        replaced = '41ffd800090000000800000000000000cdcc4c3e42fff800130000000800000000000000cdcc4c3e' ..
                   '43ff5007a60000000000000000000000cdcc4c3e'},
    [10 * 65536 + 9] = {
        stock = '41ff5800010000000800000000000000cdcc4c3e42ffd800110000000800000000000000cdcc4c3e' ..
                '43ff6806970000000800000000000000cdcc4c3e',
        replaced = '41ff5800010000000800000000000000cdcc4c3e42ffd800110000000800000000000000cdcc4c3e' ..
                   '43ff7007a80000000000000000000000cdcc4c3e'},
    [10 * 65536 + 14] = {
        stock = '41ff7800020000000800000000000000cdcc4c3e42ffe800120000000800000000000000cdcc4c3e' ..
                '43ff0006910000000000000000000000cdcc4c3e',
        replaced = '41ff7800020000000800000000000000cdcc4c3e42ffe800120000000800000000000000cdcc4c3e' ..
                   '43ff6007a70000000000000000000000cdcc4c3e'},
}
for _, slot in pairs(FIXED) do slot.stock, slot.replaced = list(slot.stock), list(slot.replaced) end
-- Each slot's keyboard mapping in the replacement (its mod default) alone.
local function mod_key(code) return FIXED[code].replaced[3] end
-- A player's own key: h (virtual key 0x48) Press, and Tab DoubleTap.
local H_KEY = hex('43ff800479000000000000000000000000000000')
local TAB_DOUBLE = hex('43ff95003a0000000500000000000000000080' .. '3e')

local position = {}
local function record(map, code) return tonumber(ffi.cast('uint64_t', map)) + position[code] * 328 end
local function set_list(map, code, mappings)
    local address = record(map, code)
    put32(address + 4, #mappings)
    ffi.fill(ffi.cast('uint8_t *', address + 8), 320)
    for index, blob in ipairs(mappings) do ffi.copy(ffi.cast('uint8_t *', address + 8 + (index - 1) * 20), blob, 20) end
end
local function get_list(map, code)
    local out, address = {}, record(map, code)
    for index = 0, get32(address + 4) - 1 do
        out[#out + 1] = ffi.string(ffi.cast('uint8_t *', address + 8 + index * 20), 20)
    end
    return out
end
-- Equal mapping lists; bytes 6-7 of a mapping are not compared (the game's
-- parser leaves them unset; the game's own compare skips them too).
local function same(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do
        if a[index]:sub(1, 6) .. a[index]:sub(9) ~= b[index]:sub(1, 6) .. b[index]:sub(9) then return false end
    end
    return true
end
local function exact(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do if a[index] ~= b[index] then return false end end
    return true
end
local LIVE, DEFAULTS = live_map, default_map
local function live(code) return get_list(LIVE, code) end
local function defaults(code) return get_list(DEFAULTS, code) end

-- The game's input configuration as a table of lists by action (content/input,
-- stock or the replacement), and a model of the game's input settings save
-- (game.dll+0x12F8C10 / +0xAFD720): the live list of every action that differs
-- from a fresh parse of content/input, by action; and its load (+0xAF26D0):
-- each saved action's list replaces the parsed one.
local DORMANT
local function config(kind)
    local out = {}
    for _, entry in ipairs(DORMANT) do
        local code = entry[1] * 65536 + entry[2]
        out[code] = FIXED[code] and FIXED[code][kind] or {}
    end
    return out
end
local function parse(map, lists)
    for code, mappings in pairs(lists) do set_list(map, code, mappings) end
end
local function save(lists)
    local saved = {}
    for code, mappings in pairs(lists) do
        local now = live(code)
        if not same(now, mappings) then saved[code] = now end
    end
    return saved
end
local function load(saved)
    for code, mappings in pairs(saved) do set_list(LIVE, code, mappings) end
end

-- A fresh Mod Bindings Menu (a new game process) with its log, its reads and
-- VirtualQuery calls counted. The build check passes unless unsupported.
local lines, reads, queries = {}, 0, 0
local log = {write = function(_, text) lines[#lines + 1] = text end, flush = function() end}
local function upvalue(fn, wanted)
    for index = 1, 80 do
        local name, value = debug.getupvalue(fn, index)
        if name == wanted then return value, index end
        if name == nil then break end
    end
    error('missing upvalue ' .. wanted)
end
local function logged(text, from)
    local found = 0
    for index = from or 1, #lines do
        if lines[index]:find(text, 1, true) then found = found + 1 end
    end
    return found
end
local function session(unsupported)
    _G.ModBindingsMenu, _G.BingusTranslations, _G.BingusRuntime = nil, nil, nil
    Text.registry().steam_language = 'en'
    _G.mbm_text = {module = Text, locales = {en = dofile(root .. '/locales/en.lua'), bundled = {}}}
    _G.CowboyBingusModLoader = {log_directory = directory, open_log = function() return log end}
    _G.update = function() end
    dofile(source)
    local menu, frame = ModBindingsMenu, update
    local st = upvalue(menu.register_binding, 'state')
    local read = upvalue(upvalue(upvalue(frame, 'step'), 'initialize'), 'read')
    local kernel32, index = upvalue(read, 'kernel32')
    debug.setupvalue(read, index, setmetatable({
        MBM_ReadProcessMemory = function(...) reads = reads + 1; return kernel32.MBM_ReadProcessMemory(...) end,
        MBM_read_at = function(...) reads = reads + 1; return kernel32.MBM_read_at(...) end,
        MBM_VirtualQuery = function(...) queries = queries + 1; return kernel32.MBM_VirtualQuery(...) end,
    }, {__index = kernel32}))
    if not unsupported then st.initialized, st.base = true, base end
    DORMANT = upvalue(upvalue(upvalue(frame, 'step'), 'initialize'), 'DORMANT_ACTIONS')
    return menu, st, frame
end
-- The game parses content/input into both maps at startup.
local function start(kind)
    local used, seed = {}, 3
    for _, entry in ipairs(DORMANT) do
        local code = entry[1] * 65536 + entry[2]
        if not position[code] then
            repeat seed = (seed * 41 + 13) % 256 until not used[seed]
            used[seed], position[code] = true, seed
        end
        for _, map in ipairs({LIVE, DEFAULTS}) do put32(record(map, code), code) end
    end
    parse(LIVE, config(kind))
    parse(DEFAULTS, config(kind))
end
local function counted(fn, ...)
    reads, queries = 0, 0
    fn(...)
    return reads, queries
end
local SSH = {{'cowboybingus.galactic_menu', 0xb46c8096, 1}, {'cowboybingus.armory', 0x19e97f02, 3},
             {'cowboybingus.control_center', 'Control Center', 4}, {'cowboybingus.ship_management', 0x2716885e, 5},
             {'cowboybingus.stratagem_hero', 'Stratagem Hero', 6}, {'cowboybingus.hellpod', 0xe89a91ef, 7}}
local function register(menu)
    for _, binding in ipairs(SSH) do assert(menu.register_binding(binding[1], binding[2], binding[3])) end
end

-- 1. A fresh install, no saved settings: the game parsed its own stock lists.
-- When native input is ready, both maps get the replacement's lists, byte for
-- byte; the 30 other dormant actions are untouched. Nothing is registered, so
-- the sweep reads nothing; no VirtualQuery. Later frames add nothing.
remove_files()
local menu, st, frame = session()
start('stock')
local from = #lines + 1
local r, q = counted(frame, 0)
assert(menu.ready() and q == 0, 'no VirtualQuery')
-- The frame native input becomes ready: 40 reads, once per session (18 before
-- this change: the live map indexed and the slot 1 log line). The keyboard
-- defaults add 22: the defaults map indexed (the owner, its header and 8 reads
-- of 32 records) and each fixed slot's defaults and live record. In game a read
-- costs about 1-2 us; this frame is not repeated.
assert(r == 40, 'activation reads: ' .. r)
for code, slot in pairs(FIXED) do
    assert(exact(defaults(code), slot.replaced), 'defaults ' .. code)
    assert(exact(live(code), slot.replaced), 'live ' .. code)
end
for _, entry in ipairs(DORMANT) do
    local code = entry[1] * 65536 + entry[2]
    if not FIXED[code] then assert(#live(code) == 0 and #defaults(code) == 0) end
end
assert(logged('Added Mod Bindings Menu\'s keyboard defaults to 12 binding records.', from) == 1)
for _ = 1, 3 do r, q = counted(frame, 0); assert(r == 2 and q == 0, 'idle frame: the page check only, ' .. r) end
print('A fresh install: both maps get the replacement\'s lists byte for byte, once, with no VirtualQuery OK')

-- 2. Registered (Ship Station Hotkeys' six): the first sweep leaves the mod
-- default alone in both maps, as with the replacement file.
register(menu)
frame(2)
for code in pairs(FIXED) do
    assert(same(live(code), {mod_key(code)}) and same(defaults(code), {mod_key(code)}), 'swept ' .. code)
end
print('First sweep: the mod key alone in both maps, as with the replacement OK')

-- 3. A device change: the game re-parses content/input into the live map, and
-- (when the action is not in the saved settings) the stock list stays. The
-- next sweep re-adds the default with no read beyond the sweep's own. is_down
-- sees the changed mapping count and sweeps at once.
set_list(LIVE, 12 * 65536 + 1, FIXED[12 * 65536 + 1].stock)
set_list(LIVE, 10 * 65536 + 4, FIXED[10 * 65536 + 4].stock)
from = #lines + 1
r, q = counted(frame, 2)
-- 12 reads (each registered action's defaults and live record) and one more per
-- restored record, which the sweep cleans: the same reads a re-parse of the
-- replacement cost; the comparison with the stock list reads nothing.
assert(q == 0 and r == 16, 'a sweep frame after a re-parse of two records: ' .. r)
assert(same(live(12 * 65536 + 1), {mod_key(12 * 65536 + 1)}) and same(live(10 * 65536 + 4), {mod_key(10 * 65536 + 4)}))
assert(logged('Added the keyboard default of 12:1 again', from) == 1)
set_list(LIVE, 10 * 65536 + 1, FIXED[10 * 65536 + 1].stock)
assert(menu.is_down(SSH[2][1]) == false and same(live(10 * 65536 + 1), {mod_key(10 * 65536 + 1)}))
-- A settings reset re-parses the defaults map: the next sweep re-adds there too.
set_list(DEFAULTS, 10 * 65536 + 8, FIXED[10 * 65536 + 8].stock)
frame(2)
assert(same(defaults(10 * 65536 + 8), {mod_key(10 * 65536 + 8)}))
-- The player's own lists are never touched, even the stock list's single keys.
set_list(LIVE, 10 * 65536 + 9, {H_KEY})
set_list(LIVE, 10 * 65536 + 14, {FIXED[10 * 65536 + 14].stock[3]})
frame(2)
assert(same(live(10 * 65536 + 9), {H_KEY}))
print('A re-parse of either map: the stock list gets the mod default again on the next sweep, no extra read OK')

-- 4. Sweep frames, also ones that compare the fixed slots, allocate nothing
-- (after the assignments file has saved the changes above).
for _ = 1, 40 do frame(2) end
jit.off()
jit.flush()
collectgarbage('collect')
collectgarbage('stop')
local before = collectgarbage('count')
for _ = 1, 20 do frame(2) end
local garbage = (collectgarbage('count') - before) * 1024
collectgarbage('restart')
jit.on()
assert(garbage == 0, string.format('sweep frames allocated %d bytes', garbage))
r, q = counted(frame, 2)
assert(r == 14 and q == 0, 'an unchanged sweep frame keeps its 14 reads: ' .. r)
print('Sweep frames allocate nothing and keep their 14 reads OK')

-- 5. The game's saved settings applied before Mod Bindings Menu is ready:
-- live records that differ from the stock list stay as they are.
remove_files()
menu, st, frame = session()
start('stock')
load({[12 * 65536 + 1] = {TAB_DOUBLE}, [10 * 65536 + 1] = {H_KEY}})
frame(0)
assert(same(live(12 * 65536 + 1), {TAB_DOUBLE}) and same(live(10 * 65536 + 1), {H_KEY}))
assert(exact(live(10 * 65536 + 4), FIXED[10 * 65536 + 4].replaced))
assert(exact(defaults(12 * 65536 + 1), FIXED[12 * 65536 + 1].replaced))
-- ...or after it (the order seen in game): the saved list replaces the added one.
remove_files()
menu, st, frame = session()
start('stock')
frame(0)
load({[10 * 65536 + 1] = {H_KEY}})
register(menu)
frame(2)
assert(same(live(10 * 65536 + 1), {H_KEY}) and same(live(12 * 65536 + 1), {mod_key(12 * 65536 + 1)}))
print('Saved settings, applied before or after: the player\'s lists stay OK')

-- 6. An unsupported game build: the build check fails, nothing is read and
-- nothing in either map changes.
remove_files()
menu, st, frame = session(true)
start('stock')
from = #lines + 1
r, q = counted(function() for _ = 1, 5 do frame(2) end end)
assert(r == 0 and q == 0 and not menu.ready(), 'no read on an unsupported build')
for code, slot in pairs(FIXED) do assert(exact(live(code), slot.stock) and exact(defaults(code), slot.stock)) end
assert(logged('inactive on this game build', from) == 1)
print('An unsupported build: no read, no write, both maps as the game parsed them OK')

-- 7. An old replacement still deployed (an older Megapack beside this
-- release): the game parsed the replacement's lists; nothing is written.
remove_files()
menu, st, frame = session()
start('replaced')
from = #lines + 1
frame(0)
for code, slot in pairs(FIXED) do assert(exact(live(code), slot.replaced) and exact(defaults(code), slot.replaced)) end
assert(logged('Added Mod Bindings Menu\'s keyboard defaults', from) == 0)
print('An old replacement still deployed: nothing written OK')

-- 8. Upgrade and downgrade with the game's own save. Under the replacement
-- (v2.3 and older) the player rebinds slot 3 to h and leaves slot 1 at Tab;
-- the game saves the diff against the replacement: slot 3's h, and slot 1's
-- Tab alone, since the sweep removed its developer mappings (as in game: the
-- saved file of a player with these bindings holds every fixed slot).
remove_files()
menu, st, frame = session()
start('replaced')
register(menu)
frame(2)
set_list(LIVE, 10 * 65536 + 1, {H_KEY})
local saved_old = save(config('replaced'))
assert(same(saved_old[10 * 65536 + 1], {H_KEY}) and same(saved_old[12 * 65536 + 1], {mod_key(12 * 65536 + 1)}))
-- A slot never used by a binding keeps the replacement's list: not saved.
saved_old[10 * 65536 + 14] = nil
-- Upgrade: the game parses its stock content/input and applies the saved file;
-- this release adds the defaults: slot 3 keeps h, slot 1 is Tab again.
remove_files()
menu, st, frame = session()
start('stock')
load(saved_old)
register(menu)
frame(0)
frame(2)
assert(same(live(10 * 65536 + 1), {H_KEY}), 'the custom key survives the upgrade')
for _, code in ipairs({12 * 65536 + 1, 10 * 65536 + 4, 10 * 65536 + 8, 10 * 65536 + 9, 10 * 65536 + 14}) do
    assert(same(live(code), {mod_key(code)}), 'mod default after the upgrade ' .. code)
end
-- Saved now (against the stock content/input): every fixed slot, h on slot 3
-- and the mod defaults, which now differ from the stock lists.
local saved_new = save(config('stock'))
assert(same(saved_new[10 * 65536 + 1], {H_KEY}) and same(saved_new[12 * 65536 + 1], {mod_key(12 * 65536 + 1)}))
-- Downgrade: the replacement is parsed and the newer file applied: the same keys.
remove_files()
start('replaced')
load(saved_new)
assert(same(live(10 * 65536 + 1), {H_KEY}), 'the custom key survives the downgrade')
for _, code in ipairs({12 * 65536 + 1, 10 * 65536 + 4, 10 * 65536 + 8, 10 * 65536 + 9, 10 * 65536 + 14}) do
    assert(same(live(code), {mod_key(code)}), 'mod default after the downgrade ' .. code)
end
print('Upgrade from and downgrade to the replacement: saved custom keys and mod defaults survive OK')
remove_files()
