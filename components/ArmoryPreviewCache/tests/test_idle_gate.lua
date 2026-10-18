-- The idle gate (install.lua) must not change what the mod does. The v23
-- update wrapper, image policy and image adapter (tests/reference/*_v23.lua,
-- byte-identical to v23 as released) and the current ones run side by side,
-- through the whole update wrapper, on two copies of the captured Armory UI
-- with the same scripted game: every change the asset snapshot reports is also
-- made in game memory. After every frame the presentation each widget element
-- shows, every native write, the manager, the retained images and the asset
-- leases, lease calls, profile and memory guard must be equal. The current
-- world also counts its api calls: an idle frame makes 2 reads, on the ship
-- and in a mission, and no other call.
--
-- One deliberate difference: with rendered images held and the Armory closed,
-- v23 polled memory every 50 ms step and the gated version every 2 s, so
-- memory pressure releases the images within 2 s instead of 50 ms. That step
-- is compared once it has settled.
local root=assert(arg[1]);local ffi=require('ffi')
local function p(n)return ffi.cast('uint8_t *',n)end
local function num(x)return type(x)=='number' and x or tonumber(ffi.cast('uintptr_t',x))end
local function u32s(v)return ffi.string(ffi.new('uint32_t[1]',v),4)end
local function ptrs(v)return ffi.string(ffi.new('uint64_t[1]',v),8)end
local function u32(s,o)return s:byte(o+1)+s:byte(o+2)*256+s:byte(o+3)*65536+s:byte(o+4)*16777216 end
local function ptr(s,o)return u32(s,o)+u32(s,o+4)*4294967296 end
local function hexs(s)return (s:gsub('.',function(c)return string.format('%02x',c:byte())end))end

local function engine(w,descriptor)
    local memory=w.memory
    local function canon(t)
        if t==nil then return 'nil' end
        local a=num(t);return w.names[a] or string.format('unknown:%x',a)
    end
    w.canon=canon
    local function write(address,bytes)
        w.log[#w.log+1]=w.frame..':'..string.format('%x',num(address))..'='..hexs(bytes)
        memory.poke(num(address),bytes)
    end
    local calls={register=function()end,register_image=function(_,e)
        local n=w.m32[2784]
        for i=0,n-1 do if w.m32[2786+i*2]+w.m32[2787+i*2]*4294967296==num(e)then return end end
        w.m32[2786+n*2]=num(e)%4294967296;w.m32[2787+n*2]=math.floor(num(e)/4294967296);w.m32[2784]=n+1
        w.log[#w.log+1]=w.frame..':register '..string.format('%x',num(e))
    end}
    calls.create=function()
        local d=ffi.new('uint8_t[104]');ffi.copy(d,descriptor,104)
        w.created[#w.created+1]=d;d[0]=0x40+#w.created
        memory.map(num(d),d,104);w.names[num(d)]='fresh'..#w.created
        return d
    end
    calls.destroy=function(t)w.destroyed[#w.destroyed+1]=w.frame..':'..canon(t)end
    calls.texture=function(e,_,t)w.texture[num(e)]=canon(t)end
    calls.uv=function(e,a,b)w.uv[num(e)]=tostring(a)..','..tostring(b)end
    calls.size=function(e,v)w.size[num(e)]=tostring(v)end
    calls.alpha=function(e,v)w.alpha[num(e)]=v end
    calls.material=function(e)
        write(num(e)+328,ptrs(0x600000000000+num(e)%0x10000000));write(num(e)+336,ptrs(0))
    end
    calls.byte=function(a,v)write(a,string.char(v))end
    return calls
end

local function world(version)
    local api,game,exe,_,memory=dofile(root..'/tests/captured_ui.lua')(root..'/tests/fixtures/ui_armory_25327279.lua')
    local sigs=dofile(root..'/src/image_signatures.lua')
    for _,s in ipairs(sigs)do
        memory.poke((s.module=='game' and game or exe)+s.rva,s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end))
    end
    memory.poke(exe+0x1658990,u32s(32))
    local w={version=version,memory=memory,clock=0,frame=0,free=8*1024^3,calls={},files={},log={},created={},
        names={},destroyed={},texture={},uv={},size={},alpha={},counts={}}
    local captured=ptr(api.read(game+0x347cd80,8),0)
    w.manager=ffi.new('uint8_t[12176]');ffi.copy(w.manager,api.read(p(captured),12176),12176)
    w.m32=ffi.cast('uint32_t *',w.manager)
    w.global=num(game)+0x347cd80
    memory.poke(w.global,ptrs(num(w.manager)));memory.map(num(w.manager),w.manager,12176)
    w.original=w.m32[2778]+w.m32[2779]*4294967296;w.names[w.original]='original'
    local descriptor=api.read(p(w.original),104)
    w.stack=ptr(api.read(game+0x347ce28,8),0)+0x429c
    w.ui=ptr(api.read(game+0x347cd90,8),0)
    -- The platform calls install.lua makes, counted per frame.
    api.assert_thread=function()end
    api.module_hash=function()return 'hash' end
    api.time=function()return w.clock end
    api.memory=function()return w.free,1024^3,16*1024^3 end
    api.process_id=1;api.process_created_filetime_hex='0000000000000000'
    for _,name in ipairs({'read','assert_thread','time','memory'})do
        local original=api[name]
        api[name]=function(...)w.counts[name]=(w.counts[name] or 0)+1;return original(...)end
    end
    local calls=engine(w,descriptor)
    local suffix=version=='v23' and '_v23.lua' or '.lua'
    local folder=version=='v23' and root..'/tests/reference/' or root..'/src/'
    local real=dofile(folder..'image_native'..suffix)
    local image_native={state=real.state,new=function(a,g,e,s,_,watch)return real.new(a,g,e,s,calls,watch)end}
    local images=dofile(folder..'images'..suffix)
    local image_module={new=function(a,o)w.cache=images.new(a,o);return w.cache end}
    local policy=dofile(root..'/src/policy.lua')
    local policy_module={new=function(a,o)w.policy=policy.new(a,o);return w.policy end,
        new_memory_guard=function()w.guard=policy.new_memory_guard();return w.guard end}
    -- The asset adapter: scripted snapshots, lease calls recorded.
    local asset={}
    function asset:snapshot()return w.snapshot end
    function asset:valid_leases()return true end
    function asset:resolve_all(item)return {'p'..item.id}end
    function asset:acquire(id)w.calls[#w.calls+1]=w.frame..':acquire '..id;return true end
    function asset:release(id)w.calls[#w.calls+1]=w.frame..':release '..id;return true end
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
    local install=setfenv(assert(loadfile(folder..'install'..suffix)),env)()
    install(function()return api end,{new=function()return asset end},policy_module,dofile(root..'/src/profile.lua'),
        {},{revision='test',game_sha256='hash',exe_sha256='hash',runtime=dofile(root..'/src/bingus_runtime.lua')},
        image_native,image_module,sigs,nil)
    w.env=env
    return w
end

local ITEMS={}
for i=1,6 do ITEMS[i]={kind=i%4,id=string.format('%016x',0x2000+i)}end
-- A game state: the stack (top, depth) and the asset snapshot for it.
local function set(w,st)
    local depth=st.depth or 1
    local top=st.top
    local items={}
    if top==5 or depth==0 then
        for i=1,6 do items[i]={kind=ITEMS[i].kind,id=ITEMS[i].id,finished=true}end
    end
    w.snapshot={owner='lease',world='world',menu=top==5 and depth>0,prefetch=depth==0,blocked=false,
        top=depth==0 and -1 or top,active=false,states={},items=items}
    w.memory.poke(w.stack,u32s(top))
    w.memory.poke(w.stack+20,u32s(depth))
    w.top,w.depth,w.mission=top,depth,st.mission==true
end

local function used_ranks(textures)
    local values={}
    for _,t in ipairs(textures)do values[#values+1]=t.used or -1 end
    table.sort(values)
    local rank={};local r=0;local last
    for _,v in ipairs(values)do if v~=last then r=r+1;rank[v]=r;last=v end end
    return rank
end
local COUNTERS={'bytes','hits','misses','last_hits','last_misses','early_hits','last_early_hits','retained',
    'released','late_switches','pending_drops','ready_items','missing_ready_items','blank_ready_items',
    'rendered_items','refreshed','changed_items','reappeared','pending_items','partial_retained','idle_retained',
    'visible_retained','evicted','grid_hits','preselect_hits','briefing_hits','clear_count','widget_count',
    'named_material_widgets','status','screen','last_clear_reason'}
local function describe(w,loose)
    -- loose: events without their frame numbers (a settled step).
    local function events(list,sep)
        local text=table.concat(list,sep)
        return loose and (text:gsub("%d+:","")) or text
    end
    local out={}
    local c=w.cache
    for _,k in ipairs(COUNTERS)do out[#out+1]=k..'='..tostring(c[k])end
    local keys={}
    for key in pairs(c.entries)do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys)do
        local e=c.entries[key]
        out[#out+1]='entry '..hexs(key)..' '..hexs(e.uv)..' '..w.canon(e.texture.handle)
    end
    -- Texture recency as ranks: idle frames run no tick, so tick numbers differ.
    local rank=used_ranks(c.textures)
    for i,t in ipairs(c.textures)do
        out[#out+1]=string.format('texture %d %s %s used rank %d %s %s',i,w.canon(t.handle),w.canon(t.replacement),
            rank[t.used or -1],tostring(t.destroyed),tostring(t.returned))
    end
    for _,section in ipairs({'texture','uv','size','alpha'})do
        local rows={}
        for e,v in pairs(w[section])do rows[#rows+1]=string.format('%s %x=%s',section,e,tostring(v))end
        table.sort(rows);for _,r in ipairs(rows)do out[#out+1]=r end
    end
    out[#out+1]='writes '..events(w.log,' ')
    out[#out+1]='destroyed '..events(w.destroyed,' ')
    out[#out+1]='created '..#w.created
    out[#out+1]='manager '..hexs(ffi.string(w.manager,11112))..' atlas='..w.canon(w.m32[2778]+w.m32[2779]*4294967296)
    local pc=w.policy
    for _,k in ipairs({'status','pressure','quarantined','seen_menu','acquires','releases','hits','unresolved',
        'retired','prewarms','startup_acquires','foreground_pending'})do
        out[#out+1]='policy '..k..'='..tostring(pc[k])
    end
    local leases={}
    for id in pairs(pc.leases)do leases[#leases+1]=id end
    table.sort(leases)
    out[#out+1]='leases '..table.concat(leases,',')
    out[#out+1]='calls '..events(w.calls,',')
    out[#out+1]='profile '..dofile(root..'/src/profile.lua').encode(pc:profile(),'build')
    for _,k in ipairs({'trips','active','last_reason'})do out[#out+1]='guard '..k..'='..tostring(w.guard[k])end
    local st=w.env.ArmoryPreviewCache
    for _,k in ipairs({'status','pressure_reason','profile_error','last_error'})do
        out[#out+1]='state '..k..'='..tostring(st[k])
    end
    return out
end
local function compare(a,b,label,loose)
    local x,y=describe(a,loose),describe(b,loose)
    for i=1,math.max(#x,#y)do
        if x[i]~=y[i]then
            local s,t=tostring(x[i]),tostring(y[i])
            local at=1;while s:sub(at,at)==t:sub(at,at)do at=at+1 end
            local from=math.max(1,at-120)
            error(string.format('%s: v23 and gated differ at line %d:\n  v23:   %s\n  gated: %s',
                label,i,s:sub(from,at+200),t:sub(from,at+200)))
        end
    end
end

local worlds={world('v23'),world('current')}
local frames,idle_checked=0,{ship=0,mission=0}
-- After a settled step the event history differs in its frame numbers: later
-- steps compare the events without them.
local timing_differs=false
-- One step: change (applied once, to both worlds), then count frames at 60
-- FPS. settle: compare only after the last frame (the 2 s memory poll).
local function run(label,count,change,settle)
    for f=1,count do
        frames=frames+1
        for _,w in ipairs(worlds)do
            if change and f==1 then change(w)end
            w.frame=frames;w.clock=w.clock+1/60
            local idle=w.env.ArmoryPreviewCache.idle_frames
            w.counts={}
            w.env.update(1/60)
            w.idle_now=w.env.ArmoryPreviewCache and idle~=w.env.ArmoryPreviewCache.idle_frames
        end
        local gated=worlds[2]
        -- A working frame reads no more than v23 did (the probe's two reads stand
        -- in for the refresh's first two), until the deliberate memory-poll timing
        -- difference.
        if not gated.idle_now and not settle and not timing_differs then
            local mine,old=gated.counts.read or 0,worlds[1].counts.read or 0
            assert(mine<=old,label..": a working frame made "..mine.." reads, v23 "..old)
        end
        if gated.idle_now then
            local where=gated.mission and 'mission' or 'ship'
            local reads=gated.counts.read or 0
            assert(reads==2 and not gated.counts.assert_thread and not gated.counts.time
                and not gated.counts.memory,label..': an idle frame ('..where..') made '..reads..' reads and '
                ..tostring(gated.counts.assert_thread)..' thread checks, '..tostring(gated.counts.time)..' clock calls, '
                ..tostring(gated.counts.memory)..' memory polls')
            idle_checked[where]=idle_checked[where]+1
        end
        if settle then timing_differs=true end
        if not settle or f==count then compare(worlds[1],worlds[2],label..' (frame '..f..')',timing_differs)end
    end
end
local SHIP={top=3}
local function state(fields)return function(w)set(w,fields)end end
local idle=function()return worlds[2].env.ArmoryPreviewCache.idle_frames end

-- Startup: an empty state stack prewarms the learned items for 60 s, then
-- the window closes (with nothing learned yet: a profile is learned in the
-- Armory) and the empty stack is idle.
run('startup, empty stack',120,state({top=0,depth=0}))
assert(idle()==0,'The startup window is never idle')
run('startup window over',60,function(w)w.clock=w.clock+61 end)
local after_startup=idle()
assert(after_startup>0,'An empty stack after the startup window is idle')
run('ship',120,state(SHIP))
-- First Armory visit: every card complete, the request is retained, leases
-- held for the visible items.
run('Armory opens',90,state({top=5}))
assert(worlds[1].cache.retained>0 and next(worlds[1].policy.leases),'The visit retains images and leases assets')
local before=idle()
run('Armory open, nothing changes',60)
assert(idle()==before,'An open Armory is never idle')
-- Leaving: the step releases the leases and the profile saves; then idle
-- with the images retained, a memory poll every 2 s.
run('left the Armory',360,state(SHIP))
assert(#worlds[2].cache.textures>0 and idle()>before+200,'Retained images keep idling')
assert(worlds[2].files['fixture/ArmoryPreviewCache.profile'],'The profile saved before idling')
-- Returning: the retained crops are shown at once.
local hits=worlds[1].cache.hits
run('back in the Armory',60,state({top=5}))
assert(worlds[1].cache.hits>hits,'The return visit shows retained images')
run('left again',120,state(SHIP))
-- A mission: the same 2 reads per idle frame as on the ship, apart from the
-- 2 s memory poll while images are held.
run('mission',600,state({top=20,mission=true}))
assert(idle_checked.mission>500,'Mission frames idle on 2 reads')
run('mission over, ship',120,state(SHIP))
-- The thumbnail manager replaced while idle with images held: the first
-- frame sees it and the image cache drops what it held, as in v23.
run('thumbnail manager replaced',60,function(w)
    local copy=ffi.new('uint8_t[12176]');ffi.copy(copy,w.manager,12176)
    w.old_manager=w.manager;w.manager=copy;w.m32=ffi.cast('uint32_t *',copy)
    w.memory.poke(w.global,ptrs(num(copy)));w.memory.map(num(copy),copy,12176)
end)
assert(#worlds[1].cache.textures==0 and worlds[1].cache.clear_count>0,'A new manager clears retained images')
-- Visit again to hold images, leave, then memory pressure while idle:
-- released within the 2 s poll (v23: the next 50 ms step).
run('Armory again',90,state({top=5}))
run('left, images held',60,state(SHIP))
assert(#worlds[2].cache.textures>0)
run('memory pressure while idle',150,function(w)w.free=1024^3 end,true)
assert(#worlds[2].cache.textures==0 and worlds[2].guard.trips>0,'Pressure releases idle images within 2 s')
run('memory back, cooldown',120,function(w)w.free=8*1024^3;w.clock=w.clock+40 end,true)
run('ship after cooldown',400)
assert(not worlds[2].guard.active,'The guard recovered')
-- A briefing on the stack is never idle (the captured controller is the
-- Armory's, so no screen is decoded; the gate still runs every frame).
before=idle()
run('briefing state on the stack',30,state({top=14}))
assert(idle()==before,'A briefing on the stack is never idle')
run('ship again',60,state(SHIP))
-- verify_gate=1 turns the idle gate off (the v23 gates still verify).
do
    local w=world('current')
    w.files['fixture/ArmoryPreviewCache.ini']='verify_gate=1'
    set(w,SHIP)
    for i=1,120 do w.frame=i;w.clock=w.clock+1/60;w.env.update(1/60)end
    assert(w.env.ArmoryPreviewCache.idle_frames==0,'verify_gate=1 runs every frame in full')
end
print(string.format('PASS: v23 and idle-gated updates give identical presentation, native writes, manager, retained images, leases, lease calls, profile and memory guard over %d frames (%d idle on the ship with 2 reads and nothing else, %d in a mission, also 2 reads): startup prewarm and its end, ship, Armory visit and retention, leaving with images held, return hits, mission, thumbnail manager replaced, memory pressure while idle (released within the 2 s poll) and recovery; never idle with a briefing on the stack or with verify_gate=1',
    frames,idle_checked.ship,idle_checked.mission))
