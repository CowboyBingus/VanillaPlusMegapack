-- The 50 ms asset step must not change behavior when its native snapshot and
-- policy tick are skipped. The ungated install.lua and policy.lua
-- (tests/reference) and the current ones run on two copies of the captured Armory UI with the
-- same scripted game: every change the asset snapshot reports is also made in
-- game memory (stack, manager, UI blocked flag, lease table), as in the game.
-- After every frame the leases (ids and recency order), learned profile,
-- counters, native lease calls, saved files, memory guard and install state
-- must be equal.
local root=assert(arg[1]);local ffi=require('ffi')
local function u32s(v)return ffi.string(ffi.new('uint32_t[1]',v),4)end
local function ptrs(v)return ffi.string(ffi.new('uint64_t[1]',v),8)end
local function num(x)return tonumber(ffi.cast('uintptr_t',x))end
local function u32(s,o)return s:byte(o+1)+s:byte(o+2)*256+s:byte(o+3)*65536+s:byte(o+4)*16777216 end
local function ptr(s,o)return u32(s,o)+u32(s,o+4)*4294967296 end

local function world(version)
    local api,game,exe,_,memory=dofile(root..'/tests/captured_ui.lua')(root..'/tests/fixtures/ui_armory_25327279.lua')
    local sigs=dofile(root..'/src/image_signatures.lua')
    for _,s in ipairs(sigs)do
        memory.poke((s.module=='game' and game or exe)+s.rva,s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end))
    end
    memory.poke(exe+0x1658990,u32s(32))
    local w={memory=memory,clock=0,calls={},files={},free=8*1024^3,refuse={}}
    local tm=ptr(api.read(game+0x347cd80,8),0)
    w.manager=ffi.new('uint8_t[12176]');ffi.copy(w.manager,api.read(ffi.cast('uint8_t *',tm),12176),12176)
    w.m32=ffi.cast('uint32_t *',w.manager)
    memory.poke(game+0x347cd80,ptrs(num(w.manager)));memory.map(num(w.manager),w.manager,12176)
    local descriptor=api.read(ffi.cast('uint8_t *',w.m32[2778]+w.m32[2779]*4294967296),104)
    w.stack=ptr(api.read(game+0x347ce28,8),0)+0x429c
    w.ui=ptr(api.read(game+0x347cd90,8),0)
    w.lease=ptr(api.read(game+0x347ceb0,8),0)
    api.assert_thread=function()end
    api.module_hash=function()return 'hash' end
    api.time=function()return w.clock end
    api.memory=function()return w.free,1024^3,16*1024^3 end
    api.process_id=1;api.process_created_filetime_hex='0000000000000000'
    local created={}
    local calls={register=function()end,destroy=function()end,texture=function()end,uv=function()end,
        size=function()end,alpha=function()end,material=function()end,register_image=function()end,
        byte=function(a,v)memory.poke(num(a),string.char(v))end}
    calls.create=function()
        local t=ffi.new('uint8_t[104]');ffi.copy(t,descriptor,104);created[#created+1]=t;t[0]=0x40+#created
        memory.map(num(t),t,104);return t
    end
    local reference=version=='ungated' and root..'/tests/reference/' or root..'/src/'
    local real=dofile(version=='ungated' and reference..'image_native_ungated.lua' or reference..'image_native.lua')
    local image_native={state=real.state,new=function(a,g,e,s,_,watch)return real.new(a,g,e,s,calls,watch)end}
    local policy=dofile(version=='ungated' and reference..'policy_ungated.lua' or reference..'policy.lua')
    local policy_module={new=function(a,o)w.policy=policy.new(a,o);return w.policy end,
        new_memory_guard=function()w.guard=policy.new_memory_guard();return w.guard end}
    -- The asset adapter: scripted snapshots, lease calls recorded.
    local asset={}
    function asset:snapshot()return w.snapshot end
    function asset:valid_leases()return not w.lost end
    function asset:resolve_all(item)
        if item.kind==4 then return {} end
        return item.kind==0 and {'p'..item.id,'d'..item.id} or {'p'..item.id}
    end
    function asset:acquire(id)
        w.calls[#w.calls+1]='acquire '..id
        return not w.refuse[id]
    end
    function asset:release(id)w.calls[#w.calls+1]='release '..id;return true end
    local env=setmetatable({CowboyBingusModLoader={api=1,open_log=function()return nil end}},{__index=_G})
    env._G=env
    local files=w.files
    env.os={getenv=function()return 'fixture' end,remove=function(name)files[name]=nil;return true end,
        rename=function(a,b)if not files[a]then return nil end;files[b]=files[a];files[a]=nil;return true end}
    env.io={open=function(name,how)
        if how=='rb' then
            if not files[name]then return nil end
            return {read=function(_,n)return files[name]:sub(1,n)end,close=function()end}
        end
        files[name]=''
        return {write=function(self,text)files[name]=files[name]..text;return self end,close=function()end}
    end}
    env.update=function()end;env.shutdown=function()end
    local install=setfenv(assert(loadfile(version=='ungated' and reference..'install_ungated.lua' or reference..'install.lua')),env)()
    install(function()return api end,{new=function()return asset end},policy_module,dofile(root..'/src/profile.lua'),
        {},{revision='test',game_sha256='hash',exe_sha256='hash',runtime=dofile(root..'/src/bingus_runtime.lua')},image_native,
        dofile(version=='ungated' and reference..'images_ungated.lua' or reference..'images.lua'),sigs,nil)
    w.env=env
    return w
end

local ITEMS={}
for i=1,10 do ITEMS[i]={kind=i%5,id=string.format('%016x',0x1000+i)}end
-- The asset snapshot the game would give for a state, and the same state in
-- game memory.
local function set(w,state)
    local items={}
    for i,base in ipairs(ITEMS)do
        if i<=state.items then
            items[#items+1]={kind=base.kind,id=base.id,finished=state.finished,attachments=state.attachments}
        end
    end
    -- An empty state stack (depth 0) with an idle preview manager is the
    -- startup state: the snapshot lists the manager's items for prewarming.
    local depth=state.depth or 1
    w.snapshot={owner='lease-'..state.owner,world='world',menu=state.top==5 and depth>0,prefetch=depth==0,
        blocked=state.blocked,top=state.top,active=not state.finished,states={},
        items=(state.top==5 or depth==0) and items or {}}
    w.memory.poke(w.stack,u32s(state.top))
    w.memory.poke(w.stack+20,u32s(depth))
    w.memory.poke(w.ui+15892,u32s(state.blocked and 1 or 0))
    -- Items and completion live in the manager: a card's state and the item
    -- count stand for both.
    for c=0,5 do w.m32[(c*1816+1832)/4]=state.finished and 8 or 5 end
    w.m32[(1836)/4]=state.items
    w.m32[(32+104)/4]=(state.attachments and 7 or 0)
    w.memory.poke(w.lease+16416,ptrs(0x10000000+state.owner))
end

local function describe(w)
    local c,out=w.policy,{}
    for _,k in ipairs({'status','pressure','quarantined','seen_menu','world','owner','acquires','releases','hits',
        'unresolved','retired','prewarms','dependency_acquires','startup_acquires','foreground_pending'})do
        out[#out+1]=k..'='..tostring(c[k])
    end
    local leases={}
    for id,l in pairs(c.leases)do leases[#leases+1]={id=id,used=l.used,owner=l.owner}end
    table.sort(leases,function(a,b)if a.used~=b.used then return a.used<b.used end;return a.id<b.id end)
    -- Recency as an order (ties grouped): skipped ticks keep the last tick's
    -- value for every lease that tick touched, which keeps the order.
    local rank,last=0,nil
    for _,l in ipairs(leases)do
        if l.used~=last then rank=rank+1;last=l.used end
        out[#out+1]='lease '..l.id..' '..tostring(l.owner)..' rank '..rank
    end
    out[#out+1]='profile '..dofile(root..'/src/profile.lua').encode(c:profile(),'build')
    out[#out+1]='calls '..table.concat(w.calls,',')
    local names={}
    for name in pairs(w.files)do names[#names+1]=name end
    table.sort(names)
    for _,name in ipairs(names)do out[#out+1]='file '..name..'='..w.files[name]end
    for _,k in ipairs({'trips','active','last_reason','trigger_free_mib','trigger_commit_mib','last_low','healthy_since'})do
        out[#out+1]='guard '..k..'='..tostring(w.guard[k])
    end
    local st=w.env.ArmoryPreviewCache
    for _,k in ipairs({'status','last_top','last_items','last_active','last_blocked','free_mib','commit_headroom_mib',
        'private_growth_mib','pressure_reason','profile_error','last_error'})do
        out[#out+1]='state '..k..'='..tostring(st[k])
    end
    return out
end
local function compare(a,b,label)
    local x,y=describe(a),describe(b)
    for i=1,math.max(#x,#y)do
        if x[i]~=y[i]then
            error(string.format('%s: ungated and gated differ at line %d:\n  ungated: %s\n  gated:   %s',label,i,tostring(x[i]),tostring(y[i])))
        end
    end
end

local SHIP={top=3,items=0,finished=true,blocked=false,owner=1}
local worlds={world('ungated'),world('gated')}
local frames=0
local function run(label,count,change)
    for _=1,count do
        frames=frames+1
        for _,w in ipairs(worlds)do
            if change then change(w)end
            w.clock=w.clock+1/60
            w.env.update(1/60)
        end
        compare(worlds[1],worlds[2],label)
        change=nil
    end
end
local function state(fields)
    local s={};for k,v in pairs(SHIP)do s[k]=v end
    for k,v in pairs(fields)do s[k]=v end
    return function(w)set(w,s)end
end
-- Startup before the first menu. The state view does not cover the manager
-- at an empty state stack, so those steps always read afresh.
run('startup prewarm',60,state({depth=0,top=-1,items=4,finished=true}))
run('startup under memory pressure',30,function(w)w.free=1024^3 end)
run('startup, memory back',30,function(w)w.free=8*1024^3;w.clock=w.clock+40 end)
run('startup window and cooldown over',30,function(w)w.clock=w.clock+40 end)
assert(worlds[2].env.ArmoryPreviewCache.policy_steps_skipped==0,'Steps at an empty state stack must read afresh')
assert(worlds[1].policy.startup_acquires>0,'The startup window must prewarm')
run('ship',30,state({}))
run('Armory opens, previews generating',60,state({top=5,items=10,finished=false}))
run('previews done: background prewarm',60,state({top=5,items=10,finished=true}))
run('UI busy',30,state({top=5,items=10,finished=true,blocked=true}))
run('UI free, attachments seen',30,state({top=5,items=10,finished=true,attachments={'a1','a2'}}))
run('memory pressure',30,function(w)w.free=1024^3 end)
-- The pressure released every lease; one of them is refused when the
-- policy asks for it again, so every step retries it.
run('memory back, cooldown',60,function(w)w.free=8*1024^3;w.refuse['p'..ITEMS[3].id]=true end)
run('cooldown passes, a lease refused',30,function(w)w.clock=w.clock+40 end)
run('fewer items, the lease still refused',30,function(w)set(w,{top=5,items=6,finished=false,blocked=false,owner=1})end)
run('lease granted again',30,function(w)w.refuse={}end)
run('back on the ship: profile saves',400,state({}))
run('lease table replaced',30,state({owner=2}))
run('lease ownership lost in the Armory',30,function(w)w.lost=true;set(w,{top=5,items=10,finished=true,blocked=false,owner=2})end)
local skipped=worlds[2].env.ArmoryPreviewCache.policy_steps_skipped
assert(skipped>0,'Steady states must skip the asset step')
local plain=worlds
assert(worlds[1].policy.acquires>0 and worlds[1].policy.releases>0 and worlds[1].guard.trips>0)
local refusals=0
for _,call in ipairs(worlds[1].calls)do if call=='acquire p'..ITEMS[3].id then refusals=refusals+1 end end
assert(refusals>=20,'The refused lease must be asked for again on each of the 20 steps that want it')
-- verify_gate=1 on the asset step: no miss while the state view covers what
-- the snapshot reads; a snapshot change the view does not see (here the stand-in
-- snapshot changes and game memory does not) is caught and read afresh.
local verify_frames=frames
worlds={world('ungated'),world('gated')}
for _,w in ipairs(worlds)do w.files['fixture/ArmoryPreviewCache.ini']='verify_gate=1' end
run('verify: ship',30,state({}))
run('verify: Armory opens, previews generating',60,state({top=5,items=10,finished=false}))
run('verify: previews done',60,state({top=5,items=10,finished=true}))
local verify_state=worlds[2].env.ArmoryPreviewCache
assert(verify_state.policy_gate_misses==0 and verify_state.policy_steps_skipped>0,'Correct reuse reports no miss')
run('verify: a change the state does not cover',30,function(w)
    local s={};for k,v in pairs(w.snapshot)do s[k]=v end
    s.blocked=true;w.snapshot=s
end)
assert(verify_state.policy_gate_misses>0,'A reused reading that changed must be caught')
verify_frames=frames-verify_frames
worlds=plain
-- settled, tick by tick: only a tick whose repeat would add nothing but the
-- same counts may be replayed.
do
    local refused={}
    local adapter={valid_leases=function()return true end,resolve_all=function(_,item)return {'p'..item.id}end,
        acquire=function(_,id)return not refused[id]end,release=function()return true end}
    local c=dofile(root..'/src/policy.lua').new(adapter,{})
    local items={{kind=1,id='a'},{kind=1,id='b'}}
    local function snapshot(menu,list)
        return {owner='o',world='w',menu=menu,prefetch=not menu,blocked=false,active=false,items=list or items}
    end
    c:tick(snapshot(false),0,true);assert(c.settled==false,'Startup under memory pressure is not settled')
    c:tick(snapshot(false),1,false);assert(c.settled==false,'A startup tick that acquired is not settled')
    c:tick(snapshot(false),2,false);assert(c.settled==false,'Startup closes with the clock alone: not settled')
    c:tick(snapshot(true),3,false);assert(c.settled==true,'Everything leased and nothing acquired is settled')
    refused.pc=true
    c:tick(snapshot(true,{items[1],items[2],{kind=1,id='c'}}),4,false)
    assert(c.settled==false,'A refused protected request is not settled')
    c:tick(snapshot(true),5,true);assert(c.settled==true,'Memory pressure after startup is settled')
    c:tick({owner='o',world='w',menu=false,prefetch=false,blocked=false,active=false,items={}},6,false)
    assert(c.settled==true,'Outside the menu is settled')
end
print(string.format('PASS: ungated and gated asset steps give identical leases, recency order, learned profile, counters, lease calls, saved files, memory guard and state after each of %d frames (%d steps skipped): startup prewarm at an empty state stack (never reused) with pressure, ship, generation, prewarm, busy UI, attachments, pressure and recovery, a refused lease retried every step, profile save, lease table change and lost ownership; settled ticks checked one by one; verify_gate reports no miss for correct reuse and catches an uncovered change (%d of the frames)',
    frames,skipped,verify_frames))
