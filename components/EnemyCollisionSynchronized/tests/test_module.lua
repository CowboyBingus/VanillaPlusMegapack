-- The module wrapper exactly as scripts/module.py writes it (build/mod.wrapper.lua):
-- every embedded chunk loads, the patch receives the generated allowlist, the
-- loader receives Bingus Shared Runtime's core and read side, and its build
-- check (the runtime's verify_build) refuses the test process, which has no
-- game.dll: no guard is installed.
-- usage: test_module.lua <mod.wrapper.lua>
local wrapper=assert(arg[1])
local printed={}
local env=setmetatable({print=function(text) printed[#printed+1]=text end},{__index=_G});env._G=env
env.CowboyBingusModLoader={api=1,version=17}
local game_update=function() return 'game' end
env.update=game_update
local chunk=assert(loadfile(wrapper))
setfenv(chunk,env)
local ok,why=pcall(chunk)
assert(ok,'The module wrapper raised: '..tostring(why))
local state=assert(rawget(env,'CorpseCollisionRepair'),'The loader did not run')
assert(state.status=='game modules unavailable' and state.active==false,tostring(state.status))
assert(env.update==game_update,'A refused install must leave the update chain alone')
local shared=rawget(env,'BingusRuntime')
assert(type(shared)=='table' and shared.versions[1] and next(shared.statuses)==nil,'The runtime ran; no guard')
assert(printed[1]=='[CorpseCollisionRepair] '..state.revision..': '..state.status)
-- The patch took the profiles as its chunk argument: without them it raises
-- while the wrapper loads, before the loader runs.
local text=assert(io.open(wrapper,'rb')):read('*a')
assert(select(2,text:gsub('end%)%(profiles%)\n',''))==1,'The patch must receive the generated profiles')
local broken=text:gsub('end%)%(profiles%)\n','end)()\n')
local env2=setmetatable({print=function() end},{__index=_G});env2._G=env2
env2.CowboyBingusModLoader={api=1,version=17}
local failed,reason=pcall(setfenv(assert(loadstring(broken,'=broken')),env2))
assert(not failed and tostring(reason):find('Corpse profiles unavailable',1,true),'A missing allowlist must fail loudly')
assert(rawget(env2,'CorpseCollisionRepair')==nil)
print('PASS: module wrapper loads every chunk, passes the generated profiles to the patch and the runtime to the loader, and refuses a process without the game')
