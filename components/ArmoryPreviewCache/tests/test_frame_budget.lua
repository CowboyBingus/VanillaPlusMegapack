-- Per-frame api budget of the whole update wrapper, as the game runs it:
-- install.lua with the real image adapter, image policy and asset policy on
-- the captured Armory UI (tests/captured_ui.lua). The asset adapter is a
-- stand-in without api calls (its native lease calls cannot run here), so the
-- counts are the state view, the image path and the policy step's own calls.
-- Limits are today's exact counts (see tests/frame_budget.lua).
local root=assert(arg[1]);local ffi=require('ffi')
local budget=dofile(root..'/tests/frame_budget.lua')
local function u32s(v)return ffi.string(ffi.new('uint32_t[1]',v),4)end
local function ptrs(v)return ffi.string(ffi.new('uint64_t[1]',v),8)end
local function num(x)return tonumber(ffi.cast('uintptr_t',x))end
local function u32(s,o)return s:byte(o+1)+s:byte(o+2)*256+s:byte(o+3)*65536+s:byte(o+4)*16777216 end
local function ptr(s,o)return u32(s,o)+u32(s,o+4)*4294967296 end

local function game_world()
    local api,game,exe,_,memory=dofile(root..'/tests/captured_ui.lua')(root..'/tests/fixtures/ui_armory_25327279.lua')
    local sigs=dofile(root..'/src/image_signatures.lua')
    for _,s in ipairs(sigs)do
        memory.poke((s.module=='game' and game or exe)+s.rva,s.hex:gsub('..',function(h)return string.char(tonumber(h,16))end))
    end
    memory.poke(exe+0x1658990,u32s(32))
    local w={memory=memory,clock=0}
    local tm=ptr(api.read(game+0x347cd80,8),0)
    w.manager=ffi.new('uint8_t[12176]');ffi.copy(w.manager,api.read(ffi.cast('uint8_t *',tm),12176),12176)
    w.m32=ffi.cast('uint32_t *',w.manager)
    memory.poke(game+0x347cd80,ptrs(num(w.manager)));memory.map(num(w.manager),w.manager,12176)
    local descriptor=api.read(ffi.cast('uint8_t *',w.m32[2778]+w.m32[2779]*4294967296),104)
    w.stack=ptr(api.read(game+0x347ce28,8),0)+0x429c
    local d=ptr(api.read(game+0x3326e68,8),0)
    local rows=api.read(ffi.cast('uint8_t *',d+5744),u32(api.read(ffi.cast('uint8_t *',d+5740),4),0)*16)
    for i=0,#rows/16-1 do if u32(rows,i*16+8)==224 then w.owner=ptr(rows,i*16)end end
    -- The platform functions install.lua uses, allocation-free.
    api.assert_thread=function()end
    api.module_hash=function()return 'hash' end
    api.time=function()return w.clock end
    api.memory=function()return 8*1024^3,1024^3,16*1024^3 end
    api.process_id=1;api.process_created_filetime_hex='0000000000000000'
    w.counts=budget.wrap(api)
    -- Engine stand-ins for the image adapter: no native calls in a test.
    local created={}
    local calls={register=function()end,destroy=function()end,texture=function()end,uv=function()end,
        size=function()end,alpha=function()end,material=function()end,register_image=function()end,
        byte=function(a,v)memory.poke(num(a),string.char(v))end}
    calls.create=function()
        local t=ffi.new('uint8_t[104]');ffi.copy(t,descriptor,104);created[#created+1]=t;t[0]=0x40+#created
        memory.map(num(t),t,104);return t
    end
    local real=dofile(root..'/src/image_native.lua')
    local image_native={state=real.state,new=function(a,g,e,s,_,watch)return real.new(a,g,e,s,calls,watch)end}
    -- The asset policy's adapter: leases always succeed; the snapshot says
    -- whether the Armory is open (set by the scenario).
    w.snapshot={owner='lease-table',world='world',menu=true,prefetch=false,blocked=false,top=5,active=false,
        states={},items={{kind=3,id='0000000000000001',finished=false}}}
    local asset={}
    function asset:snapshot()return w.snapshot end
    function asset:valid_leases()return true end
    function asset:resolve_all(item)return {item.id}end
    function asset:acquire()return true end
    function asset:release()return true end
    local env=setmetatable({CowboyBingusModLoader={api=1,open_log=function()return nil end}},{__index=_G})
    env._G=env
    -- Profile saves succeed, as in game (a failed save is retried every 5 s).
    local files={}
    env.os={getenv=function()return 'fixture' end,remove=function(name)files[name]=nil;return true end,
        rename=function(a,b)if not files[a]then return nil end;files[b]=files[a];files[a]=nil;return true end}
    env.io={open=function(name,how)
        if how=='rb' then return nil end
        files[name]=''
        return {write=function(self,text)files[name]=files[name]..text;return self end,close=function()end}
    end}
    w.files=files
    env.update=function()end;env.shutdown=function()end
    local install=setfenv(assert(loadfile(root..'/src/install.lua')),env)()
    install(function()return api end,{new=function()return asset end},dofile(root..'/src/policy.lua'),
        dofile(root..'/src/profile.lua'),{},{revision='test',game_sha256='hash',exe_sha256='hash',runtime=dofile(root..'/src/bingus_runtime.lua')},
        image_native,dofile(root..'/src/images.lua'),sigs,nil)
    w.env=env
    function w.top(v)memory.poke(w.stack,u32s(v))end
    function w.poke(a,bytes)memory.poke(a,bytes)end
    function w.card(c,st)w.m32[(c*1816+1832)/4]=st end
    function w.active(c,phase)w.m32[11064/4]=c;w.m32[11096/4]=phase end
    -- One frame of the game: before, update, after, at 60 FPS.
    function w.step()w.clock=w.clock+1/60;w.env.update(1/60)end
    function w.frame()return budget.frame(w.counts,w.step)end
    return w
end

-- Frames alternate: two without the 50 ms policy step, then one with it.
local function pin(w,label,plain,policy)
    for _=1,12 do w.step()end
    for i=1,6 do
        local frame=w.frame()
        local limits=i%3==0 and policy or plain
        budget.check(frame,limits,label..(i%3==0 and ' (policy step)' or ''))
        for name,n in pairs(limits)do
            assert((frame[name] or 0)==n,label..': expected '..name..'='..n..', got '..budget.describe(frame))
        end
    end
end
-- Garbage per frame, interpreted and compiled. With the JIT off (the
-- interpreter is the worst case) a full collection can shrink the Lua stack,
-- and a VM allocation of a few hundred bytes can follow it once (the next deep
-- call regrowing the stack): 30 settling frames run with the collector
-- stopped, then the measured ones must allocate nothing. With the JIT on,
-- traces compile during a 600-frame warm-up and a trace compiled later
-- allocates once, so the median of ten 60-frame windows must be zero.
local function garbage(w,label,frames)
    jit.off();jit.flush()
    for _=1,12 do w.step()end
    collectgarbage('collect');collectgarbage('stop')
    for _=1,30 do w.step()end
    local before=collectgarbage('count')
    for _=1,frames do w.step()end
    local bytes=(collectgarbage('count')-before)*1024
    collectgarbage('restart');jit.on()
    assert(bytes==0,label..': '..bytes..' bytes of garbage in '..frames..' interpreted frames')
    for _=1,600 do w.step()end
    local windows={}
    for i=1,10 do
        collectgarbage('collect');collectgarbage('stop')
        local start=collectgarbage('count')
        for _=1,60 do w.step()end
        windows[i]=(collectgarbage('count')-start)*1024
        collectgarbage('restart')
    end
    table.sort(windows)
    assert(windows[6]==0,label..': median '..windows[6]..' bytes of garbage in 60 compiled frames')
end

-- Every frame checks the update thread once (was twice: before and after the
-- game update).
-- On the ship: the thumbnail screen is closed. 3 reads (globals, state stack,
-- UI world); the policy step adds the lease owner (2 reads) and the clock for
-- the profile-save throttle. Memory telemetry, whose pressure reason changes
-- nothing outside a menu with no leases or images held, runs once every 2 s
-- (was every policy step); the pinned frames fall between two polls.
local ship=game_world()
ship.top(3);ship.snapshot.menu=false;ship.snapshot.top=3
pin(ship,'ship',{assert_thread=1,read=3},{assert_thread=1,read=5,time=1})
-- Longer than the 5 s profile-save throttle: nothing learned, nothing encoded.
garbage(ship,'ship',720)
assert(ship.files['fixture/ArmoryPreviewCache.profile'],'The first save wrote the profile')
do
    local polls=0
    for _=1,240 do polls=polls+(ship.frame().memory or 0)end
    assert(polls==2,'ship: '..polls..' memory polls in 4 s, expected one every 2 s')
    -- Opening a menu polls on its first policy step, whatever the idle wait.
    for _=1,3 do ship.step()end
    ship.snapshot.menu=true
    polls=0
    for _=1,3 do polls=polls+(ship.frame().memory or 0)end
    assert(polls==1,'ship: the first policy step in a menu polls memory')
    ship.snapshot.menu=false
end
-- Armory grid, every card stuck preparing (as with --toaster_mode): nothing
-- completes, nothing is bound. 10 reads: globals, stack, UI world, dispatch
-- pointer and rows, manager, atlas descriptor, preview queue header,
-- pre-select block, grid block. The policy step adds 2 lease reads and
-- memory telemetry.
local stuck=game_world()
for c=0,5 do stuck.card(c,5)end;stuck.active(0,5)
pin(stuck,'grid, nothing bound',{assert_thread=1,read=10},{assert_thread=1,read=12,memory=1})
garbage(stuck,'grid, nothing bound',120)
-- Armory grid, category complete and all 15 tiles bound to a retained crop:
-- the second refresh before the game update (bindings exist) and one texture
-- ownership read.
local warm=game_world()
pin(warm,'grid, 15 bound',{assert_thread=1,read=21},{assert_thread=1,read=23,memory=1})
garbage(warm,'grid, 15 bound',120)
-- Weapon pre-select open, its card preparing: the pre-select block and the
-- three widget record pointers replace the grid block (12 reads).
local preselect=game_world()
dofile(root..'/tests/synthetic_screens.lua').preselect(preselect.poke,preselect.owner,0)
preselect.card(0,5);preselect.active(0,5)
pin(preselect,'pre-select',{assert_thread=1,read=12},{assert_thread=1,read=14,memory=1})
garbage(preselect,'pre-select',120)
print('PASS: per-frame budget: ship 3 reads; Armory grid unchanged 10 reads (nothing bound) or 21 (15 retained crops bound); pre-select 12; policy step +2 reads, one memory poll in a menu and one per 2 s on the ship; one thread check per frame; no garbage in any unchanged scenario, interpreted or compiled')
