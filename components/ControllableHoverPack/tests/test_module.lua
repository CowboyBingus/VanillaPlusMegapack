-- The built module (build/mod.ljbc) in a host without game.dll: the build's
-- thunk must create the memory API from the embedded runtime files (the read
-- side extended by the write side) before the build check, which then
-- refuses the host and installs nothing.
local module = assert(arg[1])
local env = setmetatable({CowboyBingusModLoader = {api = 1, version = 12}, print = function() end,
    os = {getenv = function() end}}, {__index = _G})
env._G = env
local before = function(...) return ... end
env.update = before
setfenv(assert(loadfile(module)), env)()
local state = env.HoverPackCancel
assert(state and state.status:find('Required modules unavailable', 1, true), state and state.status)
assert(env.update == before, 'a refused build installs nothing')
local shared = env.BingusRuntime
assert(type(shared) == 'table' and shared.versions[1] == true and shared.hash_reads == 0,
    'the embedded read side loaded and hashed no module')
print('PASS: built module: the embedded runtime creates the memory API; the build check refuses a host without game.dll')
