-- HD2-Addon: mods/cowboybingus/vpm_forecast_panel
-- Vanilla Plus Megapack for HellForge: the one part of Know Your Constellation's forecast panel that needs the game's
-- Lua, the engine Gui calls (stingray.Gui, World, Application, Material). The pack's DLL does everything else: it reads
-- the mission, computes the forecast, decides when and where the panel shows, lays it out and asks for each call
-- (src/components/know_your_constellation/kyc_lua.c). Bingus Shared Loader starts this file from the pack's data patch.
--
-- How: attach once to the already loaded DLL with one dispatcher (an ffi callback); from then on, each update reads
-- the bridge's `work` and, only when it is not 0, calls the DLL once, which calls the dispatcher back for each engine
-- call the panel needs. The dispatcher makes that call and keeps the engine's objects behind numbers.
-- Idle cost: the update reads one integer and returns; no call, no allocation.
-- Every function here stays out of the JIT: the DLL calls back into Lua while this file calls it, which LuaJIT does
-- not allow from compiled code, and nothing here is hot enough to compile.
local options = ...
if type(options) ~= 'table' then options = {} end
local jit = rawget(_G, 'jit')
if jit then jit.off(true, true) end
local env = options.env or _G
if rawget(env, 'VpmForecastPanel') then return end
local status = {state = 'starting'}
rawset(env, 'VpmForecastPanel', status)

local ffi = require('ffi')
local engine = options.engine or rawget(env, 'stingray')
local DLL = options.dll or 'vanilla_plus_megapack.dll'
local VERSION = 1
local TRIES, EVERY = 60, 60 -- looking for the DLL: every 60th frame, 60 times, when it was not there at start

local previous = rawget(env, 'update')
if not (engine and engine.Gui and engine.World and engine.Application and engine.Material) then
    status.state = 'off: the game GUI is unavailable'
    return
end
if type(previous) ~= 'function' then
    status.state = 'off: the game update is unavailable'
    return
end

-- kyc_lua.h's KycLuaCall and KycLuaBridge, field for field.
if not pcall(ffi.typeof, 'vpm_kyc_call') then
    ffi.cdef [[
        typedef struct vpm_kyc_call {
            int32_t op, capacity;
            double world, gui, item;
            double x, y, z, w, h;
            double size, value;
            uint8_t a, r, g, b;
            uint32_t length;
            const char *text;
            char id[2][24];
            double out[3];
            double refs[64];
            char error[192];
        } vpm_kyc_call;
        typedef struct vpm_kyc_bridge { uint32_t version; volatile int32_t work; } vpm_kyc_bridge;
        vpm_kyc_bridge *vpm_kyc_lua_attach(uint32_t version, uint32_t call_size, int (*dispatch)(vpm_kyc_call *));
        void vpm_kyc_lua_apply(void);
        void *vpm_kyc_GetModuleHandleA(const char *name) __asm__("GetModuleHandleA");
    ]]
end

local App, World, Gui, Material = engine.Application, engine.World, engine.Gui, engine.Material
local Vector2, Vector3, Color, IdString64 = engine.Vector2, engine.Vector3, engine.Color, engine.IdString64

-- The engine's objects behind numbers: the worlds last listed (and the main world), the GUIs made, each GUI's
-- rectangles and texts, and the material last fetched (the DLL sets it up at once).
local worlds, guis, items, material, last = {}, {}, {}, nil, 0
local function new_ref() last = last + 1 return last end
local function world_ref(world, into)
    for ref, known in pairs(worlds) do
        if known == world then into[ref] = world return ref end
    end
    local ref = new_ref()
    into[ref] = world
    return ref
end
local function id(call, k) return IdString64.from_hex(ffi.string(call.id[k])) end
local function text(call) return ffi.string(call.text, call.length) end
local function colour(call) return Color(call.a, call.r, call.g, call.b) end
local function place(call) return Vector3(call.x, call.y, call.z) end
local function item(call)
    local list = items[call.gui]
    return list and list[call.item]
end
local function add(call, value)
    if not value then return 0 end
    local list = items[call.gui]
    list[#list + 1] = value
    call.item = #list
    return 1
end

-- One handler per op (kyc_lua.h), in kyc_gui.h's order; each returns 1, 0 or -1 as kyc_lua.h says.
local handlers = {
    function(call) -- main_world
        local main = App.main_world()
        if not main then return 0 end
        call.world = world_ref(main, worlds)
        return 1
    end,
    function(call) -- worlds
        local list = App.worlds()
        if not list then return -1 end
        local listed, n = {}, 0
        for _, world in ipairs(list) do
            if n == call.capacity then break end
            call.refs[n] = world_ref(world, listed)
            n = n + 1
        end
        worlds = listed
        return n
    end,
    function(call) -- create_screen_gui
        local world = worlds[call.world]
        local gui = world and World.create_screen_gui(world, 'scale', 1, 1)
        if not gui then return 0 end
        call.gui = new_ref()
        guis[call.gui], items[call.gui] = gui, {}
        return 1
    end,
    function(call) -- destroy_gui
        local world, gui = worlds[call.world], guis[call.gui]
        guis[call.gui], items[call.gui] = nil, nil
        if world and gui then World.destroy_gui(world, gui) end
        return 1
    end,
    function(call) -- material
        local gui = guis[call.gui]
        material = gui and Gui.material(gui, id(call, 0))
        if not material then return 0 end
        call.item = 1
        return 1
    end,
    function(call) Material.set_scalar(material, id(call, 0), call.value) return 1 end,
    function(call) Material.set_vector2(material, id(call, 0), Vector2(call.x, call.y)) return 1 end,
    function(call) Material.set_vector4(material, id(call, 0), colour(call)) return 1 end,
    function(call) Material.set_texture(material, id(call, 0), id(call, 1)) return 1 end,
    function(call) -- resolution
        local w, h = Gui.resolution()
        if not (w and h) then return 0 end
        call.w, call.h = w, h
        return 1
    end,
    function(call) -- text_extents: bit 1 min, 2 max, 4 caret
        local gui = guis[call.gui]
        if not gui then return 0 end
        local got, out = 0, call.out
        local lo, hi, caret = Gui.text_extents(gui, text(call), id(call, 0), call.size)
        if lo then out[0], got = Vector2.x(lo), got + 1 end
        if hi then out[1], got = Vector2.x(hi), got + 2 end
        if caret then out[2], got = Vector2.x(caret), got + 4 end
        return got
    end,
    function(call) -- rect
        local gui = guis[call.gui]
        return gui and add(call, Gui.rect(gui, place(call), Vector2(call.w, call.h), colour(call))) or 0
    end,
    function(call) -- update_rect
        local gui, rect = guis[call.gui], item(call)
        if not (gui and rect) then return 0 end
        Gui.update_rect(gui, rect, place(call), Vector2(call.w, call.h), colour(call))
        return 1
    end,
    function(call) -- text
        local gui = guis[call.gui]
        return gui and add(call, Gui.text(gui, text(call), id(call, 0), call.size, id(call, 1), place(call),
            colour(call))) or 0
    end,
    function(call) -- update_text
        local gui, label = guis[call.gui], item(call)
        if not (gui and label) then return 0 end
        Gui.update_text(gui, label, text(call), id(call, 0), call.size, id(call, 1), place(call), colour(call))
        return 1
    end,
}

-- No error may leave the callback (it would unwind through the DLL): an engine error goes back as -2 and its text.
local function dispatch(call)
    local handler = handlers[call.op]
    local ok, result = false, 'unknown op ' .. tostring(call.op)
    if handler then ok, result = pcall(handler, call) end
    if ok then return result end
    local message = tostring(result)
    local n = math.min(#message, 191)
    ffi.copy(call.error, message, n)
    call.error[n] = 0
    return -2
end
local callback = ffi.cast('int (*)(vpm_kyc_call *)', dispatch)
status.callback = callback -- kept for the session

local kernel = ffi.load('kernel32')
local attached, bridge, apply = false, nil, nil
-- true when there is nothing more to try: attached, or refused for good.
local function attach()
    if kernel.vpm_kyc_GetModuleHandleA(DLL) == nil then
        status.state = "waiting: the pack's DLL is not loaded"
        return false
    end
    local ok, lib = pcall(ffi.load, DLL)
    if not ok then
        status.state = 'off: ' .. tostring(lib)
        return true
    end
    local got = lib.vpm_kyc_lua_attach(VERSION, ffi.sizeof('vpm_kyc_call'), callback)
    if got == nil then
        status.state = "off: the pack's DLL refused this Lua part (another version)"
        return true
    end
    status.lib, bridge, apply, attached = lib, got, lib.vpm_kyc_lua_apply, true
    status.state = 'attached'
    return true
end
local function draw() apply() end
local tries, wait = attach() and TRIES or 0, 0
if tries == TRIES and not attached then return end

local function update(...)
    if attached then
        if bridge.work ~= 0 then pcall(draw) end
    elseif tries < TRIES then
        wait = wait + 1
        if wait == EVERY then
            wait, tries = 0, tries + 1
            if attach() then tries = TRIES end
            if tries == TRIES and not attached then status.state = status.state .. ' (gave up)' end
        end
    end
    return previous(...)
end
rawset(env, 'update', update)
