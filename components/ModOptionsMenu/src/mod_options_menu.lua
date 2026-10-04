-- HD2-Addon: mods/cowboybingus/mod_options_menu
-- Native MODS tab on the Options screen for Steam build 25480438.
if rawget(_G, 'ModOptionsMenu') then return end
local ffi = require('ffi')
-- Texts and translations: mom_text = {module = src/bingus_text.lua, locales =
-- locales/}; the other source files: mom_files.<name> = src/<name>.lua as a
-- function, each run once below. The build places both ahead of this file as
-- locals (tests provide them as globals). translation: the text module, MOM's
-- own texts and every translation helper, in one table.
local translation = {T = mom_text.module}
-- Bingus Shared Runtime (src/bingus_runtime.lua and src/bingus_memory.lua,
-- vendored byte-identical; mom_files too, each returning its table): the
-- core's guard holds the update chain (below), and the read side hashes the
-- game's module files once per session for every mod (src/native.lua).
local runtime = mom_files.bingus_runtime()
local memory = mom_files.bingus_memory().new(runtime)

ffi.cdef [[
typedef unsigned char MOM_u8;
typedef unsigned int MOM_u32;
typedef unsigned long long MOM_u64;
]]
-- Widget positions and sizes: two floats passed by value in one register.
if not pcall(ffi.typeof, 'MOM_vec2') then ffi.cdef 'typedef struct { float x, y; } MOM_vec2;' end
-- MOM's guarded read under a private name. LuaJIT keeps the first prototype
-- declared for a name in the whole game, so the real name would get whatever
-- prototype another mod declared first; the __asm__ label names the export.
-- It takes its address as an integer, so a read allocates nothing (the
-- runtime's read takes a pointer, which interpreted code would box per read),
-- and reports the bytes read as two 32-bit halves.
ffi.cdef [[
int hd2mom_ReadProcessMemory(void *process, MOM_u64 address, void *buffer, size_t size,
                             MOM_u32 *received) __asm__("ReadProcessMemory");
]]
local process = memory.windows.kernel32.GetCurrentProcess()
local loader = rawget(_G, 'CowboyBingusModLoader')
local log_file
if loader and type(loader.open_log) == 'function' then
    pcall(function() log_file = loader.open_log('ModOptionsMenu.log') end)
end
local function note(message)
    if log_file then pcall(function() log_file:write(message .. '\n'); log_file:flush() end) end
end
-- MOM's own texts, in the game's language when a translation has them.
translation.tr = translation.T.new(mom_text.locales.en, mom_text.locales.bundled,
                                   function(message) note('Text: ' .. message) end)

-- mods: option categories in the order they were first registered (at most
-- 112); refused: the mods refused for want of a category, the first
-- refused_count of them. mods_page: the page of mods the category buttons
-- show when there are more than 8 (src/view.lua).
-- values: applied values; pending: the player's unapplied edits, by option id.
-- queued: options set from code whose rows the next checked step updates.
-- saved, written: the values file's entries (id -> text) and its text as last
-- read or written; dirty, save_timer: a save is due when the timer runs out;
-- save_failed: the last save failed (its failure is logged once).
-- mods_title, empty_text: MOM's own texts, resolved when the escape menu opens.
-- The update's error counts and status are the guard's (below):
-- BingusRuntime.statuses.ModOptionsMenu.
local state = {initialized = false, base = nil, native = nil, mods = {}, refused = {}, refused_count = 0,
               mods_page = 0, options = {}, option_count = 0, values = {}, pending = {}, pending_count = 0,
               queued = {}, queued_any = false, saved = nil, callbacks = {}, texts = {}, text_addresses = {},
               revision = 0, dirty = false, save_timer = 0, view = nil, mods_tab_logged = false, menu_seen = false,
               language = nil, mods_title = 'MODS', empty_text = 'NO MOD OPTIONS INSTALLED'}

-- Memory ---------------------------------------------------------------------

-- ReadProcessMemory guards the two reads that follow pointers not yet known
-- to be live, the UI stack and the escape menu screen, so a stale pointer
-- fails the read instead of the game. The address passes as an integer and
-- values land in reused buffers, so a read allocates nothing.
local read_memory = ffi.load('kernel32').hd2mom_ReadProcessMemory
local received, word = ffi.new('MOM_u32[2]'), ffi.new('MOM_u32[2]')
local function fill(target, address, size)
    return read_memory(process, address, target, size, received) ~= 0
        and received[0] == size and received[1] == 0
end
local function valid_pointer(value) return value >= 0x10000 and value < 0x800000000000 end
local function read_pointer(address)
    if not fill(word, address, 8) then return nil end
    local value = word[0] + word[1] * 4294967296
    return valid_pointer(value) and value or nil
end
-- translation.read: up to 16 bytes as a string, for the game's Text Language.
translation.bytes = ffi.new('MOM_u8[16]')
function translation.read(address, size)
    if size > 16 or not fill(translation.bytes, address, size) then return nil end
    return ffi.string(translation.bytes, size)
end
-- Everything else is loaded and stored directly: game.dll's image stays
-- mapped, and the escape menu screen is in use by the game while it is on top
-- of the UI stack, the same frames in which MOM writes to it and hands it to
-- native functions. Typed pointers based at address 0 turn an address into an
-- index, so a load returns a plain number: no system call, no allocation.
-- 32-bit and 64-bit fields are 4-byte aligned.
local BYTES, WORDS, FLOATS = ffi.cast('MOM_u8 *', 0), ffi.cast('MOM_u32 *', 0), ffi.cast('float *', 0)
local function get8(address) return BYTES[address] end
local function get32(address) return WORDS[address / 4] end
local function getf(address) return FLOATS[address / 4] end
local function get64(address) return WORDS[address / 4] + WORDS[address / 4 + 1] * 4294967296 end
-- Writes only touch the escape menu's heap objects, never game.dll sections.
local function put8(address, value) BYTES[address] = value end
local function put32(address, value) WORDS[address / 4] = value end
local function putf(address, value) FLOATS[address / 4] = value end
-- Reused position arguments; a call copies the value.
local PIVOT, position = ffi.new('MOM_vec2', 0.5, 1), ffi.new('MOM_vec2') -- row pivot and anchor
local function vector(x, y)
    position.x, position.y = x, y
    return position
end
-- Memory the game reads with 16-byte SSE loads (movaps faults on anything
-- less) must be 16-byte aligned, but ffi.new only guarantees 8. The aligned
-- part is carved from a larger zeroed block, which the caller keeps alive.
local function aligned(size)
    local block = ffi.new('MOM_u8[?]', size + 15)
    local offset = (16 - tonumber(ffi.cast('MOM_u64', block)) % 16) % 16
    return ffi.cast('MOM_u8 *', block) + offset, block
end

-- Source files ---------------------------------------------------------------

-- mom: what the source files share. Each file runs once, in this order, takes
-- what it uses as locals (so every call and constant costs what it did when
-- MOM was one file) and adds to mom what later files and the update use.
local mom = {memory = memory, loader = loader, note = note, translation = translation, state = state,
             fill = fill, valid_pointer = valid_pointer, read_pointer = read_pointer, get8 = get8, get32 = get32,
             getf = getf, get64 = get64, put8 = put8, put32 = put32, putf = putf, PIVOT = PIVOT, vector = vector,
             aligned = aligned}
mom_files.native(mom)  -- game.dll's functions and labels, verified once per session
mom_files.widgets(mom) -- text widgets, the MODS tab, category buttons, description box
mom_files.options(mom) -- registered texts, option values and the option model
mom_files.rows(mom)    -- option rows and category pages
mom_files.view(mom)    -- the MODS view: idle gate, entering and leaving, apply and dialog
mom_files.api(mom)     -- the API other mods use

-- Update ---------------------------------------------------------------------

local initialize, escape_menu, ensure_mods_tab = mom.initialize, mom.escape_menu, mom.ensure_mods_tab
local save_values, drop_pending = mom.save_values, mom.drop_pending
local enter_view, leave_view, maintain_view = mom.enter_view, mom.leave_view, mom.maintain_view
local update_apply, update_visuals, neutralize_dialog = mom.update_apply, mom.update_visuals, mom.neutralize_dialog
local TAB_BAR, TAB_CURRENT, MODS_TAB = mom.TAB_BAR, mom.TAB_CURRENT, mom.MODS_TAB

local function step(dt)
    if not state.initialized then initialize() end
    if not state.native then return end
    if state.dirty then
        state.save_timer = state.save_timer - (type(dt) == 'number' and dt or 0)
        if state.save_timer <= 0 then save_values() end
    end
    local screen, status = escape_menu()
    local view = state.view
    -- A view dropped with the menu (closed or rebuilt) never applies its edits;
    -- reopening the escape menu re-initialises every widget we touched.
    if status == 'closed' then
        state.menu_seen = false
        if view then state.view = nil; drop_pending(); note('Escape menu closed on the MODS tab.') end
        return
    end
    if status ~= 'open' then return end
    if not state.menu_seen then
        -- The menu just opened. Its OPTIONS tab is where the game's Text
        -- Language changes, so the language is read and the texts refreshed
        -- here, once per opening.
        state.menu_seen = true
        translation.observe()
        translation.tr:refresh()
        translation.refresh()
    end
    if view and view.screen ~= screen then state.view, view = nil, nil; drop_pending() end
    if not ensure_mods_tab(screen) then
        if view then state.view = nil; drop_pending() end
        return
    end
    local tab = get32(screen + TAB_BAR + TAB_CURRENT)
    if view then
        if tab ~= MODS_TAB then leave_view(view) else maintain_view(view) end
    elseif tab == MODS_TAB then
        enter_view(screen)
    end
    view = state.view
    if view then
        update_apply(view)
        update_visuals(view, type(dt) == 'number' and dt or 0)
        neutralize_dialog(view)
    end
end

_G.ModOptionsMenu = mom.api

-- Hands an open MODS view back to the game as on leaving the tab, but only
-- while its escape menu is still open on top: a covered or closed menu's view
-- is just dropped, as when the menu closes, and so is any view when the game
-- shuts down (touch_menu false), when MOM leaves the menu alone. The view is
-- dropped first, so nothing (the API included) touches the escape menu's rows
-- again. A value save still due is written.
local function reset_view(touch_menu)
    local view = state.view
    state.view = nil
    drop_pending()
    if view and touch_menu then
        local screen, status = escape_menu()
        if status == 'open' and screen == view.screen then leave_view(view) end
    end
    if state.dirty then save_values() end
end

-- The update guard (Bingus Shared Runtime) runs step before the previous
-- update every frame, and the previous update outside pcall, so an error below
-- reaches the game unchanged. Errors count in bursts that end after 3600
-- frames without one, MOM's own apart from those below: 8 in one burst stop
-- the step for the session (the API keeps working). Every argument and return
-- value pass through. stop: once, when the guard stops (the view goes back to
-- the game) or the game shuts down (a due save is written, the menu left
-- alone).
local function stop(reason)
    local done, why = pcall(reset_view, reason ~= 'shutdown')
    if not done then note('Options shutdown failed: ' .. tostring(why)) end
end
-- pause: an update below raised. The view goes back to the game the same way
-- and MOM starts afresh, as when the escape menu opens; the guard runs step
-- again once the updates below have returned on 60 frames in a row. A
-- hand-back that raises stops the guard instead.
local function pause()
    reset_view(true)
    state.menu_seen = false
end
-- The guard's lines (a burst's first error, a pause, a resume, the stop) go to
-- the log as the update's own lines did: 'Options update error: ...'.
local GUARD = 'ModOptionsMenu'
local function guard_line(line)
    if line:sub(1, #GUARD + 1) == GUARD .. ' ' then line = 'Options update ' .. line:sub(#GUARD + 2) end
    note(line)
end
local installed, failure = pcall(function()
    runtime.guard({name = GUARD, step = step, stop = stop, pause = pause, log = guard_line, env = _G}).install()
end)
note(installed and 'Mod Options Menu initialized.' or ('Mod Options Menu has no update: ' .. tostring(failure)))
