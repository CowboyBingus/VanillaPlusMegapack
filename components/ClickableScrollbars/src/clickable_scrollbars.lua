-- HD2-Addon: mods/cowboybingus/clickable_scrollbars
-- Click-to-scroll: the visible menu's own scroll model follows the pointer.
-- Unsupported or hidden menus are inert; gestures never capture or inject input.
-- Loader-only: plaintext Lua, no DLL, no hook, no code patch. See docs/RESEARCH.md.

-- A second copy of the addon loads nothing: the first one runs.
if rawget(_G, 'ClickableScrollbars') then return end

local module = {revision = 'v2.15'}

-- Keeps these functions, and the functions defined inside them, in the
-- interpreter; without the jit library it does nothing. A function that gets
-- hot on its own becomes a trace root in the machine-code cache the game and
-- every mod share. The native layer (native, memory, locate and model) runs
-- only on presses and while a scrollbar is held. In v2.14 its traces aborted
-- on the closures each call created; closure-free, it would now add about
-- 70 KB of machine code to the shared cache for frames that only occur during
-- a drag. Each of its files keeps its functions in the interpreter, with the
-- closures of the reader, the memory view and the game routine wrappers.
local function keep_interpreted(functions)
    local jit_library = rawget(_G, 'jit')
    if jit_library and jit_library.off then
        for _, fn in ipairs(functions) do jit_library.off(fn, true) end
    end
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-- Source files: cs_files.<name> = src/<name>.lua as a function, each run once
-- below, in this order. The build places them ahead of this file as the local
-- cs_files; the tests load that built entry. cs: what the files share. Each
-- file takes what it uses as locals, so every call and constant costs what it
-- did when the addon was one file, and adds to module and cs what later files
-- use. src/detector.lua, the legacy pixel detector, is not shipped: only the
-- offline tests load it.
local cs = {keep_interpreted = keep_interpreted, clamp = clamp}
cs.runtime = cs_files.bingus_runtime(module, cs) -- Bingus Shared Runtime: the update guard (vendored)
cs_files.native(module, cs)   -- the UI bridge, the game's scroll routines and the native writes
cs_files.memory(module, cs)   -- memory views and the reader the addon ships with
cs_files.locate(module, cs)   -- resolving the visible scrollbar's owner
cs_files.model(module, cs)    -- the owner's scroll model, read in blocks
cs_files.settings(module, cs) -- defaults, the optional ini and the display scale
cs_files.platform(module, cs) -- the Windows functions the runtime calls
cs_files.install(module, cs)  -- the runtime: presses, held drags, the log and the error policy

if rawget(_G, '__CLICKABLE_SCROLLBARS_TEST') then
    return module
end

local ok, reason = module.install(module.create_platform)
if not ok then
    local loader = rawget(_G, 'CowboyBingusModLoader')
    print('[ClickableScrollbars] ' .. tostring(reason))
    pcall(function()
        local file = loader and loader.open_log and loader.open_log('ClickableScrollbars.log')
        if file then
            file:write(module.revision .. '\nstatus=' .. tostring(reason) .. '\n')
            file:close()
        end
    end)
end
