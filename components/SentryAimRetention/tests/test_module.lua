-- The module wrapper exactly as scripts/module.py writes it (build/mod.wrapper.lua):
-- every embedded chunk loads, the thunk hands the adapter the runtime's read side
-- extended by its write side, and the loader then refuses the test process, which
-- has no game.dll, without touching the update chain.
-- usage: test_module.lua <mod.wrapper.lua>
local wrapper=assert(arg[1])
local ffi=require('ffi')
local printed={}
local env=setmetatable({print=function(text)printed[#printed+1]=text end},{__index=_G});env._G=env
env.CowboyBingusModLoader={api=1,version=17}
local game_update=function()return 'game' end
env.update=game_update
local text=assert(io.open(wrapper,'rb')):read('*a')
for _,name in ipairs({'runtime','runtime_memory','runtime_write','create_api','patch','install_loader'}) do
    assert(text:find('\nlocal '..name..' = (function()\n',1,true) or text:find('^local '..name..' = %(function%(%)\n'),
        'The wrapper must embed '..name)
end
local ok,why=pcall(setfenv(assert(loadstring(text,'=mod.wrapper.lua')),env))
assert(ok,'The module wrapper raised: '..tostring(why))
local state=assert(rawget(env,'SentryAimRetention'),'The loader did not run')
-- The status is the assert's message, after its source position. Creating the
-- adapter succeeded: without the write side it raises before the build check.
assert(tostring(state.status):find(': game modules unavailable$') and state.active==false,tostring(state.status))
assert(env.update==game_update,'A refused install must leave the update chain alone')
assert(printed[1]=='[SentryAimRetention] '..state.revision..': '..state.status,tostring(printed[1]))
assert(pcall(ffi.typeof,'bingus_memory1_region') and pcall(ffi.typeof,'bingus_write1_declared'),
    'The thunk must load the read side and extend it with the write side')
assert(type(rawget(env,'BingusRuntime'))=='table','The runtime keeps its session table in the mod environment')
print('PASS: module wrapper loads every chunk, hands the adapter the extended runtime memory api and refuses a process without the game')
