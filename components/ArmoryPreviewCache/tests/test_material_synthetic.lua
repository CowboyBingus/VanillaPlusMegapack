-- Actual native adapter with synthetic addresses and recording native stand-ins.
-- No live process, captured memory, engine calls or operating-system writes.
local root=assert(arg[1]);local ffi=require('ffi')
local api=dofile(root..'/src/read_api.lua')()
local function p(n)return ffi.cast('uint8_t *',n)end
local memory={}
local function put(a,b)memory[tonumber(ffi.cast('uintptr_t',a))]=b end
local function word(n)return ffi.string(ffi.new('uint32_t[1]',n),4)end
local function ptr(n)return ffi.string(ffi.new('uintptr_t[1]',n),8)end
api.read=function(a,n)
    a=tonumber(ffi.cast('uintptr_t',a))
    for at,b in pairs(memory)do if a>=at and a+n<=at+#b then return b:sub(a-at+1,a-at+n)end end
    error('Unexpected synthetic read')
end
local game,exe=p(0x10000000),p(0x20000000)
local app,sm,ui,dispatch,tm,owner,world,widget,record,atlas=0x30000000,0x30010000,0x30020000,0x30030000,0x30040000,0x30050000,0x30060000,0x30070000,0x30080000,0x30090000
put(game+0x3326308,ptr(0x227c8d80));put(exe+0x27c8d80+16,ptr(app))
for off,rva in pairs({[368]=0x31af50,[400]=0x31b360,[528]=0x31e030})do put(app+off,ptr(0x20000000+rva))end
put(exe+0x1658990,word(32));put(game+0x347ce28,ptr(sm));put(sm+0x429c,word(14)..string.rep('\0',16)..word(1))
put(game+0x347cd90,ptr(ui));put(ui+15432,ptr(world));put(game+0x3326e68,ptr(dispatch))
put(dispatch+5740,word(1));put(dispatch+5744,ptr(owner)..word(229)..word(0))
put(game+0x347cd80,ptr(tm));put(tm+11112,ptr(atlas));put(tm+11136,word(1))
put(widget+1984,ptr(record));put(widget+272,word(0xc0000));put(widget+2005,'\1')
put(record,'visual01');put(record+60,string.rep('\0',8));put(record+68,'\0');put(atlas,'atlas001')
local element=p(widget+272);local material=ptr(0x30100000);put(element+328,material)
local textures,registrations,clone,forbidden=0,0,false,false
local calls={}
calls.texture=function(e)
    assert(not forbidden,'Retired/replaced native material must never receive a texture call')
    assert(api.pointer(api.read(e+328,8)),'Null material would crash native clone')
    textures=textures+1
    if clone then put(e+328,ptr(0x30200000))end
end
calls.register_image=function(_,e)assert(api.pointer(api.read(e+328,8)));registrations=registrations+1 end
calls.material=function()end;calls.byte=function()end
calls.uv=function()end;calls.size=function()end;calls.alpha=function()end
local a=dofile(root..'/src/image_native.lua').new(api,game,exe,{},calls)
local w={key='equipment',owner=p(owner),world=p(world),controller_kind=229,widget=p(widget),element=element,
    record_pointer=ptr(record),visual='visual01',indices=string.rep('\0',8),bound=true,fit=1,box_width=128,box_height=128,native_ready=false}
local s={widgets={w}};local entries={equipment={width=128,height=128,uv=string.rep('\0',16),texture={handle=p(atlas),id='atlas001'}}}
local function bind()
    forbidden=false;put(element+328,material);put(widget+2005,'\1');w.bound=true;w.named_material=false
    assert(a:apply(s,entries)==1);textures=0
end
bind();put(element+328,ptr(0));put(widget+2005,'\0');forbidden=true
a:prune();a:restore(false);assert(textures==0)
bind();put(element+328,ptr(0x30300000));forbidden=true
a:restore(false);assert(textures==0)
bind();a:prune();assert(textures==0);a:restore(false);assert(textures==1)
clone=true;bind();clone=false;a:prune();a:restore(false);assert(textures==1,'Track post-clone identity')
bind();put(element+328,ptr(0));w.named_material=true;forbidden=true
local hits,misses=a:apply(s,entries);assert(hits==0 and misses==1 and registrations==0)
print('PASS: synthetic production-adapter material lifetime: cleared/replaced instances rejected; valid cleanup; post-clone ownership; failed initialization remains a miss')
