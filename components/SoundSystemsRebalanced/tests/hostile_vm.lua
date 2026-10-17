-- hostile_vm.lua: the game's shared Lua state, made hostile, for mod tests.
-- Canonical copy: github.com/CowboyBingus/BingusSharedRuntime, hostile_vm.lua.
-- A mod repo keeps a byte-identical copy as tests/hostile_vm.lua.
--
-- In Helldivers 2 the game and every mod share ONE LuaJIT 2.1.0-alpha state
-- (bin/lua51.dll, non-GC64): one set of C declarations, one C type table, one
-- GC, one JIT code cache and one global update chain. A test VM is friendly:
-- nobody else declared a C function, the type table is nearly empty, the test
-- owns update, and the GC and JIT keep their defaults. These helpers bring
-- back what other mods do to that state, so that a test fails where the game
-- would misbehave or crash. Pure Lua + FFI, Lua 5.1 syntax: runs in a LuaJIT
-- 2.1 executable and in the game's lua51.dll (game_lua.py, same repository).
--
--   local H = dofile(tests .. '/hostile_vm.lua')
--
-- H.clash(names) -> status
--   Imitates a mod that loaded first and declared the same Windows function
--   names with other prototypes. ffi.cdef keeps the FIRST prototype declared for
--   a name in the whole process and silently ignores later ones, so a mod that
--   declares GetModuleHandleA under its global name gets someone else's
--   prototype in the game. Declares each name, each in pcall, as
--     int <name>(int32_t *a, int32_t *b, int32_t *c, int32_t *d, int32_t *e, int32_t *f);
--   A mod that relies on the global name then fails with "cannot convert" or
--   "wrong number of arguments" instead of passing by luck; private names with
--   an __asm__ label keep working. Call it before the mod or the test declares
--   anything. status[name] = 'clashed', 'already declared' (an earlier cdef in
--   this VM won: the name is not hostile) or 'error: <message>'.
--
-- H.next_ctype() -> id
--   The id the next new C type gets: tonumber(ffi.typeof('struct { int
--   hostile_vm_probe; }')). Each probe itself takes 2 ids (struct and field).
--
-- H.ctype_growth(fn, ...) -> count, fn's results
--   How many C types fn(...) created, the probes' own ids excluded. The game's C
--   type table has 65,536 entries for the game and every mod and never frees
--   one; once it is full every mod's FFI type creation fails. A function-pointer
--   type string creates 3 new types on every evaluation and an anonymous struct
--   2, so per-frame and per-call code must show 0. Arrays and pointers of named
--   types are interned: a first call may add a few, so measure a repeated call.
--   Errors from fn propagate.
--
-- H.chain(env, kind [, options]) -> neighbour
--   Installs an abusive neighbour around env.update (env holds the global
--   update: _G in the game, the test's environment table otherwise). Call it
--   before the mod installs to put the neighbour below the mod (the mod's
--   previous update), after to put it above (it calls the mod). Kinds:
--     'throw_below'     runs the wrapped update, then raises the table error
--                       object {hostile_vm = 'throw_below', frame = n}, like a
--                       failing game update or inner mod. A mod must let the
--                       same table pass, and neither catch it nor rethrow it as
--                       its own error. options.raise_on: nil (every frame), a
--                       frame number, or function(frame) -> boolean.
--     'drop_args'       forwards only the first argument (dt), like neighbours
--                       written as function(dt) ... end; return values pass.
--     'double_call'     calls the wrapped update twice per frame (a double install).
--     'skip_odd_frames' skips the wrapped update on frames 1, 3, 5, ... (a
--                       neighbour that returns early).
--     'rehook'          after each frame wraps env.update once more in a new
--                       pass-through closure: env.update changes identity every
--                       frame and the chain grows a layer per frame, like a
--                       neighbour that re-hooks to stay on top.
--   neighbour fields: kind, fn (installed function), inner (the function it
--   wraps), frames (times fn ran), calls (times it called inner), raised and
--   last_error (throw_below), layers (rehook: closures added).
--
-- H.chain_restore(env) -> boolean
--   Puts env.update back as it was before the first H.chain on env (anything
--   installed after that is dropped too); false when there is nothing to restore.
--
-- H.gc_hostile([pause]) -> restore
--   Sets the GC pause to 400 (or pause), as a neighbour can for the whole state:
--   the heap then grows to 4x its live size before each cycle. The game's
--   non-GC64 heap must stay below 2 GB and an out-of-memory error in compiled
--   code kills the game, so a mod's allocation bursts must stay small even then
--   (measure them with H.heap_peak). restore() sets the previous pause back.
--
-- H.jit_churn() -> flush
--   flush() calls jit.flush() (tests only) and returns how many flushes it made.
--   A full code cache (by default 512 KB and 1000 traces for the game and every
--   mod) or a neighbour discards every compiled trace the same way. Call it
--   between frames: a mod must behave the same interpreted, freshly compiled
--   and after any flush (e.g. FFI type punning that goes stale under the JIT).
--
-- H.aligned16(address [, label]) -> address
--   Raises unless address (a pointer cdata or a number) is 16-byte aligned. The
--   game's native functions load 16-byte arguments with movaps, which faults
--   and kills the game on anything else, while ffi.new only guarantees 8 bytes.
--   Call it in native fakes so that tests fail where the game would crash.
--
-- H.heap_peak(fn, ...) -> kb, fn's results
--   Lua heap growth in KB while fn(...) runs with the GC stopped: everything fn
--   allocates, including garbage a running GC would collect. Runs a full
--   collection first and restarts the GC afterwards, also when fn raises (the
--   error is raised again); assumes the GC was running before (the game's
--   LuaJIT has no collectgarbage('isrunning')). JIT trace records count too.
local ffi = require('ffi')

local H = {}
H.PROBE_IDS = 2
H.CLASH_PROTOTYPE = 'int %s(int32_t *a, int32_t *b, int32_t *c, int32_t *d, int32_t *e, int32_t *f);'

-- True when this VM already has a C declaration for name (whichever won).
local function declared(name)
    local ok, problem = pcall(function() return ffi.C[name] end)
    return ok or not tostring(problem):find('missing declaration', 1, true)
end

function H.clash(names)
    local status = {}
    for _, name in ipairs(names) do
        if declared(name) then
            status[name] = 'already declared'
        else
            local ok, problem = pcall(ffi.cdef, string.format(H.CLASH_PROTOTYPE, name))
            status[name] = ok and 'clashed' or ('error: ' .. tostring(problem))
        end
    end
    return status
end

function H.next_ctype()
    return tonumber(ffi.typeof('struct { int hostile_vm_probe; }')) -- lint-ok: R2 the probe creates one type on purpose
end

local function growth_result(before, ...)
    return H.next_ctype() - before - H.PROBE_IDS, ...
end

function H.ctype_growth(fn, ...)
    local before = H.next_ctype()
    return growth_result(before, fn(...))
end

local originals = setmetatable({}, {__mode = 'k'})

local function should_raise(raise_on, frame)
    if raise_on == nil then return true end
    if type(raise_on) == 'number' then return frame == raise_on end
    return raise_on(frame) and true or false
end

local wrappers = {}

function wrappers.throw_below(neighbour, inner, options)
    local function after(frame, ...)
        if should_raise(options.raise_on, frame) then
            neighbour.raised = neighbour.raised + 1
            neighbour.last_error = {hostile_vm = 'throw_below', frame = frame}
            error(neighbour.last_error)
        end
        return ...
    end
    return function(...)
        neighbour.frames = neighbour.frames + 1
        neighbour.calls = neighbour.calls + 1
        return after(neighbour.frames, inner(...))
    end
end

function wrappers.drop_args(neighbour, inner)
    return function(dt)
        neighbour.frames = neighbour.frames + 1
        neighbour.calls = neighbour.calls + 1
        return inner(dt)
    end
end

function wrappers.double_call(neighbour, inner)
    return function(...)
        neighbour.frames = neighbour.frames + 1
        neighbour.calls = neighbour.calls + 2
        inner(...)
        return inner(...)
    end
end

function wrappers.skip_odd_frames(neighbour, inner)
    return function(...)
        neighbour.frames = neighbour.frames + 1
        if neighbour.frames % 2 == 1 then return end
        neighbour.calls = neighbour.calls + 1
        return inner(...)
    end
end

function wrappers.rehook(neighbour, inner, _, env)
    local function after(...)
        local current = env.update
        env.update = function(...) return current(...) end
        neighbour.layers = neighbour.layers + 1
        return ...
    end
    return function(...)
        neighbour.frames = neighbour.frames + 1
        neighbour.calls = neighbour.calls + 1
        return after(inner(...))
    end
end

function H.chain(env, kind, options)
    local inner = env.update
    if type(inner) ~= 'function' then error('H.chain: env.update is not a function', 2) end
    local wrap = wrappers[kind]
    if not wrap then error('H.chain: unknown kind ' .. tostring(kind), 2) end
    if originals[env] == nil then originals[env] = inner end
    local neighbour = {kind = kind, inner = inner, frames = 0, calls = 0, raised = 0, layers = 0}
    neighbour.fn = wrap(neighbour, inner, options or {}, env)
    env.update = neighbour.fn
    return neighbour
end

function H.chain_restore(env)
    local original = originals[env]
    if original == nil then return false end
    env.update, originals[env] = original, nil
    return true
end

function H.gc_hostile(pause)
    local previous = collectgarbage('setpause', pause or 400) -- lint-ok: R4 test helper: a neighbour's GC pause
    return function()
        collectgarbage('setpause', previous) -- lint-ok: R4 test helper: restores the pause
    end
end

function H.jit_churn()
    local flushes = 0
    return function()
        flushes = flushes + 1
        jit.flush() -- lint-ok: R5 test helper: a full code cache or a flushing neighbour
        return flushes
    end
end

function H.aligned16(address, label)
    label = label or 'H.aligned16'
    local offset
    if type(address) == 'number' then
        offset = address % 16
    elseif type(address) == 'cdata' and address ~= nil then
        offset = tonumber(ffi.cast('uintptr_t', address) % 16)
    else
        error(string.format('%s: expected a non-NULL pointer or an address, got %s', label, tostring(address)), 2)
    end
    if offset ~= 0 then
        error(string.format('%s: buffer is %d bytes past a 16-byte boundary; the game\'s movaps code faults on it',
                            label, offset), 2)
    end
    return address
end

local function heap_result(before, ok, ...)
    local after = collectgarbage('count')
    collectgarbage('restart') -- lint-ok: R4 test helper: restarts the GC heap_peak stopped
    if not ok then
        local problem = ...
        error(problem, 0)
    end
    return after - before, ...
end

function H.heap_peak(fn, ...)
    collectgarbage('collect') -- lint-ok: R4 test helper: settle the heap before measuring
    collectgarbage('stop') -- lint-ok: R4 test helper: nothing is collected while fn runs
    local before = collectgarbage('count')
    return heap_result(before, pcall(fn, ...))
end

return H
