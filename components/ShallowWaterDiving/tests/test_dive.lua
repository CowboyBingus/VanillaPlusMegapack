local source=assert(arg[1])
local ffi=require('ffi')
local patch=assert(loadfile(source..'/dive_data.lua'))()
local regions={}
local function region(address,size)
    local data=ffi.new('uint8_t[?]',size);regions[#regions+1]={address=address,size=size,data=data};return data
end
local function put(data,o,kind,v) ffi.copy(data+o,ffi.new(kind..'[1]',v),ffi.sizeof(kind)) end
local function u(d,o,v) put(d,o,'uint32_t',v) end
local function p(d,o,v) put(d,o,'uint64_t',v) end
local function f(d,o,v) put(d,o,'float',v) end
local function number(d,o) return tonumber(ffi.cast('float *',d+o)[0]) end
local function locate(address,size)
    for _,r in ipairs(regions) do
        if address>=r.address and address+size<=r.address+r.size then return r.data+address-r.address end
    end
    error(string.format('Unbounded fixture access %x + %x',address,size))
end
local game,pm,mode,owner,am,dm,sm,mm=0x10000000,0x20000000,0x21000000,0x30000000,0x40000000,0x50000000,0x51000000,0x52000000
for rva,ptr in pairs({[0x3326468]=pm,[0x33266a0]=mode,[0x346bf98]=owner,[0x3326d20]=am,[0x3326a80]=dm,[0x3326598]=sm,[0x3326558]=mm}) do p(region(game+rva,8),0,ptr) end
for rva,v in pairs({[0x23c6ccc]=0.9,[0x23c69f8]=0.4}) do f(region(game+rva,4),0,v) end
-- Build 25480438 layout: the 2.0 dive timeout sits 0x10 above its old address
-- (like both stance constants); another value now occupies the old one.
do local constants=region(game+0x23c7080,0x100);f(constants,0x90,2);f(constants,0x80,1.5) end
local players,mission,avatars,drown,stances,motion=region(pm,0x400),region(mode,0x44),region(am,0x550000),region(dm,80),region(sm,72),region(mm,0x48e0)
local player=region(0x22000000,24);p(players,0xe8,0x22000000);player[20]=1
u(players,0x3a8,9);u(players,0x84,2);u(players,0x88,2);u(mission,8,1);u(mission,0x40,1)
local function map(header,o,address,key,index)
    p(header,o,address);u(header,o+8,16);u(header,o+12,0xffffffff);u(header,o+16,1)
    local rows=region(address,128)
    for i=0,15 do u(rows,8*i,0xffffffff) end
    u(rows,key%16*8,key);u(rows,key%16*8+4,index);return rows
end
map(region(owner+0xf22ec8,20),0,0x53000000,9,1)
local entities=region(owner+0xf32f18,48)
for i=0,1 do
    ffi.copy(entities+i*24,'\151\250\077\041\077\051\028\077',8)
    u(entities,i*24+8,i==0 and 111 or 222);u(entities,i*24+12,i==0 and 333 or 444);entities[i*24+20]=1
    p(avatars,0x110+i*8,owner+0xf32f18+i*24)
end
local ar=map(avatars,0xf8,0x53100000,222,1);u(ar,111%16*8,111);u(ar,111%16*8+4,0);u(avatars,0x6c,2)
map(drown,32,0x53200000,222,1);u(drown,8,2)
local entityptrs=region(0x53300000,16);p(entityptrs,0,owner+0xf32f18);p(entityptrs,8,owner+0xf32f18+24);p(drown,56,0x53300000)
local waters=region(0x53400000,56);p(drown,64,0x53400000)
local enables=region(0x53500000,4);p(drown,72,0x53500000)
map(stances,24,0x53600000,222,1);local stance=region(0x53700000,112);p(stances,56,0x53700000)
map(motion,0x48a0,0x53800000,222,1);local pos=region(0x53900000,88);p(motion,0x48d8,0x53900000)
local resource=region(0x54000000,122*16+6*64);p(region(owner+0xf12e20,8),0,0x54000000)
ffi.copy(resource,'\151\250\077\041\077\051\028\077',8);u(resource,8,5)
u(resource,122*16+5*64,0x4a182741);f(resource,122*16+5*64+4,-1.3)
local local_ctl=0x53d900+0x1238;u(avatars,local_ctl+0xb84,222)
local water,position=waters+28,pos+44
local offset_address,elapsed_address=0x53400000+28+8,0x53400000+28+16
local writes,fail,change_guard,deny=0,nil,false,false
local api={distance=function(a,b)return a-b end}
api.read=function(a,size) return ffi.string(locate(a,size),size) end
api.pointer=function(b,o)
    if not b then return end
    local v=ffi.new('uint64_t[1]');ffi.copy(v,b:sub((o or 0)+1),8)
    local n=tonumber(v[0]);if n>=0x10000 and n<0x800000000000 then return n end
end
api.writable_data=function(a,size)
    if change_guard then change_guard=false;f(water,24,-0.8) end
    return not deny and size==4 and (a==offset_address or a==elapsed_address)
end
api.write=function(a,b)
    assert(api.writable_data(a,#b),'Write outside local water floats');writes=writes+1
    if fail==writes then ffi.copy(locate(a,#b),b,2);return false end
    ffi.copy(locate(a,#b),b,#b);return true
end
local state
local function reset()
    state={observed=0,protected=0,restored=0,startup_clears=0,short_ends=0}
    writes=0;fail=nil;deny=false;change_guard=false
    u(players,0x3a8,9);u(mission,0x40,1);u(entities,24+8,222)
    u(avatars,local_ctl+0xf88,0);u(avatars,local_ctl+0xf8c,0x20)
    f(avatars,local_ctl+0xb84+8,0);f(avatars,local_ctl+0xb84+12,0)
    enables[2]=1;enables[3]=1
    f(water,8,-0.3999999761581421);f(water,16,0.011);f(water,20,4.989);f(water,24,-1.3967556476593018)
    water[0]=1;water[1]=0;u(water,4,0)
    u(stance,56+28,2);f(position,8,-1.5967556476593018);position[32]=1
    f(waters,8,-9);f(waters,16,7)
end
local function apply()return patch.apply(api,game,0,state)end
local function near(a,b)assert(math.abs(a-b)<1e-6,tostring(a)..' != '..tostring(b))end
for mode=1,7 do
    reset();u(mission,0x40,mode);assert(apply());assert(state.protected==1,'dive rejected mission mode '..mode)
    assert(patch.restore(api,state.pending))
end
for _,mode in ipairs({0,8,0xffffffff})do
    reset();u(mission,0x40,mode);assert(apply());assert(writes==0)
end
reset();u(mission,0x40,2);u(mission,8,0);assert(apply());assert(writes==0);u(mission,8,1)

-- Replay the first-prone-frame startup debt with a synthetic 20 cm water
-- surface. The historical 60 cm failure must now retain vanilla restrictions.
for _,depth in ipairs({-0.1,0,0.01,0.15,0.199,0.20,0.201,0.25,0.30,0.301,0.45,0.8})do
    reset();f(water,24,number(position,8)+depth)
    assert(apply());local allowed=depth>0 and depth<=0.20
    assert((state.protected==1)==allowed,'Incorrect depth boundary: '..depth)
    if allowed then assert(patch.restore(api,state.pending))else assert(writes==0)end
end
reset();f(water,24,-0.9994804859161377);assert(apply());assert(writes==0,'Historical 60 cm water is no longer assisted')
reset();assert(apply());near(number(water,8),-1.3);near(number(water,16),0)
assert(state.protected==1 and state.startup_clears==1 and writes==2)
assert(not (enables[2]~=0 and enables[3]~=0 and number(water,16)>0),'Startup would still enter swimming')
local function native_water_update()
    local submerged=number(water,24)>number(position,8)-number(water,8)
    water[0]=submerged and 1 or 0;f(water,16,submerged and 0.011 or 0)
    return submerged
end
assert(not native_water_update(),'Protected reference still classifies launch as submerged')
local prior=writes;assert(apply());assert(writes==prior,'Active lease rewrote native data')
near(number(waters,8),-9);near(number(waters,16),7)

-- Dry landing restores prone without triggering water. Wet landing restores
-- the original water decision at the native landing timer, not a guessed delay.
f(water,24,-3);f(avatars,local_ctl+0xb84+12,0.5)
assert(apply());near(number(water,8),-0.4);assert(not native_water_update());assert(not state.pending)
reset();assert(apply());f(water,24,-0.9994804859161377);f(avatars,local_ctl+0xb84+12,0.5);assert(apply())
near(number(water,8),-0.4);assert(native_water_update(),'Wet landing should permit native swimming')
reset();assert(apply());f(water,24,1);assert(apply());near(number(water,8),-0.4);assert(native_water_update())

-- Ordinary prone, existing swimming, ragdoll, already deep water and older
-- dives never acquire an offset lease.
for _,kind in ipairs({'prone','swim','ragdoll','deep','old','landing','drowned','disabled','other_owner'}) do
    reset()
    if kind=='prone' then u(avatars,local_ctl+0xf8c,0)
    elseif kind=='swim' then u(avatars,local_ctl+0xf88,0x80000000)
    elseif kind=='ragdoll' then u(avatars,local_ctl+0xf8c,0x30)
    elseif kind=='deep' then f(water,24,1)
    elseif kind=='old' then f(avatars,local_ctl+0xb84+8,0.2)
    elseif kind=='landing' then f(avatars,local_ctl+0xb84+12,0.5)
    elseif kind=='drowned' then f(water,20,0)
    elseif kind=='disabled' then enables[2]=0
    elseif kind=='other_owner' then f(water,8,-0.8) end
    assert(apply());assert(writes==0,kind..' was changed')
end
reset();enables[3]=0;f(water,24,0);f(water,16,0);assert(apply());assert(writes==0)
reset();assert(apply());enables[3]=0;assert(apply());assert(not state.pending);near(number(water,8),-0.4)
reset();assert(apply());f(water,24,number(position,8)+0.21);assert(apply());assert(not state.pending);near(number(water,8),-0.4)
reset();assert(apply());f(avatars,local_ctl+0xb84+8,2);assert(apply());near(number(water,8),-0.4)

-- Engine transitions, exceptions/shutdown restoration, record reuse and
-- local-player changes must never put old prone bytes on a standing/new avatar.
reset();assert(apply());u(avatars,local_ctl+0xf8c,0);u(stance,56+28,0);assert(apply());near(number(water,8),-1.3)
reset();assert(apply());f(water,8,-0.8);assert(patch.restore(api,state.pending));near(number(water,8),-0.8)
reset();assert(apply());u(entities,24+8,999);prior=writes;assert(patch.restore(api,state.pending));assert(writes==prior)
reset();assert(apply());u(players,0x3a8,0x7fff);assert(apply());near(number(water,8),-0.4)
reset();assert(apply());u(mission,0x40,0);assert(apply());near(number(water,8),-0.4)
reset();change_guard=true;assert(apply());assert(writes==0)
reset();deny=true;assert(not apply());assert(writes==0)
for at=1,2 do
    reset();fail=at;assert(not apply());near(number(water,8),-0.4)
    near(number(water,16),0.011)
end
reset();assert(apply());assert(patch.restore(api,state.pending));near(number(water,8),-0.4)
reset();assert(apply());fail=3;assert(not patch.restore(api,state.pending))
assert(patch.restore(api,state.pending));near(number(water,8),-0.4)
reset();water[1]=1;assert(apply());assert(writes==0)
reset();f(water,16,0.1);assert(apply());assert(writes==0)

-- Boot can call update before native managers/players exist. These waits must
-- survive the production apply function, then accept a later real dive.
local missing_pointers={
    {game+0x33266a0,mode},{game+0x3326468,pm},{pm+0xe8,0x22000000},
    {game+0x346bf98,owner},{game+0x3326d20,am},{game+0x3326a80,dm},
    {dm+56,0x53300000},{dm+64,0x53400000},{dm+72,0x53500000},
    {game+0x3326598,sm},{sm+56,0x53700000},{game+0x3326558,mm},
    {mm+0x48d8,0x53900000},{owner+0xf12e20,0x54000000},
}
for _,item in ipairs(missing_pointers) do
    reset();p(locate(item[1],8),0,0)
    for i=1,3 do local ok,reason=apply();assert(ok and reason:find('waiting_for_',1,true)==1);assert(writes==0) end
    p(locate(item[1],8),0,item[2]);assert(apply());assert(state.protected==1)
end
reset();u(drown,40,0);assert(apply());assert(writes==0);u(drown,40,16);assert(apply());assert(state.protected==1)
reset();u(stance,56+28,3);assert(apply());assert(writes==0);u(stance,56+28,2);assert(apply());assert(state.protected==1)
reset();position[32]=0;assert(apply());assert(writes==0);position[32]=1;assert(apply());assert(state.protected==1)
reset();assert(apply());p(locate(pm+0xe8,8),0,0);assert(apply());near(number(water,8),-0.4)
p(locate(pm+0xe8,8),0,0x22000000)
-- Nonzero invalid pointers and unsupported settings remain real errors.
reset();p(locate(game+0x33266a0,8),0,123);assert(not pcall(apply));assert(writes==0)
p(locate(game+0x33266a0,8),0,mode)
reset();f(resource,122*16+5*64+4,-1.1);assert(not pcall(apply));assert(writes==0)
f(resource,122*16+5*64+4,-1.3)
-- Timeout constant: the old address still works as a fallback, and when 2.0 is
-- at neither address the mod stops and names where 2.0 was seen nearby.
local constants=locate(game+0x23c7080,0x100)
local function timeout_layout(new,old) f(constants,0x90,new);f(constants,0x80,old) end
reset();timeout_layout(0,2);assert(pcall(apply),'old-address fallback')
reset();timeout_layout(0,0);f(constants,0x20,2)
local ok,message=pcall(apply)
assert(not ok and tostring(message):find('Native dive timeout changed (2.0 near expected block at: 0x23c70a0)',1,true),
    tostring(message))
f(constants,0x20,0);reset();timeout_layout(2,1.5);assert(pcall(apply),'build 25480438 layout')
-- Outside a dive only the identity and dive records are read; a dive frame
-- still reads and validates everything, and a dive ending releases the lease.
do
    local raw_read,reads=api.read,0
    api.read=function(a,size) reads=reads+1;return raw_read(a,size) end
    reset();u(avatars,local_ctl+0xf8c,0)
    local ok,reason=apply();local idle=reads
    assert(ok and reason=='dive_ended' and idle<20,'idle frame read '..idle..' times: '..tostring(reason))
    reads=0;reset();assert(apply() and state.protected==1)
    assert(reads>idle*2,'dive frame reads the full snapshot')
    u(avatars,local_ctl+0xf8c,0);local released,why=apply()
    assert(released and why=='dive_ended' and state.restored==1,'lease released when the dive ends: '..tostring(why))
    api.read=raw_read
end
print('PASS: idle frames skip the water/stance/movement/settings reads; dives still read everything and release on end')
print('PASS: dive timeout at the build 25480438 address, old-address fallback and located failure message')
print('PASS: 20 cm depth limit, no dry/reset-surface assistance, restoration above 20 cm, startup debt, landings, prone/ragdoll/timeout, local ownership and write failures')
print('PASS: null managers/player pointers, empty records and transient stance/motion wait then recover; invalid pointers and settings still fail')
