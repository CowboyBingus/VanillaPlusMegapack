local source=assert(arg[1])
local ffi=require('ffi')
-- Before anything in this process declares them: another mod that loaded
-- first declared every Windows name this mod's code binds (the runtime's, the
-- translation module's and the tick count the adapter used to read) with a
-- wrong prototype (tests/hostile_vm.lua, H.clash). ffi.cdef keeps the first
-- prototype of a name for the whole game, so everything below, the Windows
-- adapter block included, runs against those clashing declarations.
local H=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'hostile_vm.lua')
local CLASHED={'GetModuleHandleA','GetModuleFileNameW','GetCurrentProcess','ReadProcessMemory','WriteProcessMemory',
    'VirtualQuery','QueryPerformanceCounter','QueryPerformanceFrequency','CreateFileW','ReadFile','CloseHandle',
    'BCryptOpenAlgorithmProvider','BCryptCloseAlgorithmProvider','BCryptCreateHash','BCryptHashData',
    'BCryptFinishHash','BCryptDestroyHash','GetTickCount64','GetProcAddress'}
do
    local count=0
    for name,status in pairs(H.clash(CLASHED)) do assert(status=='clashed',name..': '..status);count=count+1 end
    assert(count==#CLASHED)
end
local patch=assert(loadfile(source..'/dive_data.lua'))()
local regions={}
local function region(address,size)
    local data=ffi.new('uint8_t[?]',size)
    regions[#regions+1]={address=address,size=size,data=data,at=tonumber(ffi.cast('uintptr_t',data))}
    return data
end
local function put(data,o,kind,v) ffi.copy(data+o,ffi.new(kind..'[1]',v),ffi.sizeof(kind)) end
local function u(d,o,v) put(d,o,'uint32_t',v) end
local function p(d,o,v) put(d,o,'uint64_t',v) end
local function f(d,o,v) put(d,o,'float',v) end
local function number(d,o) return tonumber(ffi.cast('float *',d+o)[0]) end
local function find(address,size)
    for i=1,#regions do
        local r=regions[i]
        if address>=r.address and address+size<=r.address+r.size then return r,address-r.address end
    end
    error(string.format('Unbounded fixture access %x + %x',address,size))
end
local function locate(address,size) local r,o=find(address,size);return r.data+o end
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
local rows_owner=map(region(owner+0xf22ec8,20),0,0x53000000,9,1)
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
local writes,fail,change_guard,deny=0,nil,false,false
local api={}
-- change_guard={address, count, change}: after count reads of address, change()
-- alters the game data before the next read of it returns. With count=1 on a
-- snapshot record, that is the coherence check reading it again before any write.
local water_record=0x53400000+28
-- As the Windows adapter: read(address, size) returns a string, and
-- read(address, size, into, offset) copies into the caller buffer and returns
-- true. Like ReadProcessMemory, the copy is a C call on number addresses: it
-- allocates nothing (the garbage checks below measure the mod only) and the
-- JIT cannot reuse loads of the buffer from before it.
ffi.cdef('void RtlMoveMemory(void *destination, const void *source, size_t length);')
local move=ffi.cast('void (*)(uint64_t, uint64_t, size_t)',ffi.C.RtlMoveMemory)
api.read=function(a,size,into,offset)
    local g=change_guard
    if g and a==g.address then
        g.count=g.count-1
        if g.count<0 then change_guard=false;g.change() end
    end
    if into then
        offset=offset or 0
        if size<=0 or offset<0 or offset+size>into.size then return nil end
        local r,o=find(a,size)
        move(into.address+offset,r.at+o,size)
        return true
    end
    return ffi.string(locate(a,size),size)
end
-- Water-record tables the page check approves: each is one 56-byte region
-- (records 0 and 1), and only the local record's two floats (record 1, +8 and
-- +16) may be written. A test moves the table by adding a copy elsewhere.
local tables={0x53400000}
local function water_table(a,size)
    for i=1,#tables do
        local t=tables[i]
        if a>=t+28+8 and a+size<=t+28+20 then return t end
    end
end
-- As the Windows adapter: true and the checked region, refused on a denied page.
-- Like a heap segment, one region holds both table locations, so a moved table
-- can sit inside the span an earlier check approved.
api.writable_data=function(a,size)
    local t=not deny and water_table(a,size)
    if not t then return false end
    return true,0x53400000,0x53500000
end
-- As the Windows adapter: a write checks its page unless the caller passes
-- checked=true. Only a denied page may refuse; anything else is a stray write.
api.write=function(a,b,checked)
    local t=water_table(a,#b)
    assert(t and #b==4 and (a==t+28+8 or a==t+28+16),'Write outside local water floats')
    if not checked and not api.writable_data(a,#b) then assert(deny,'Write outside local water floats');return false end
    writes=writes+1
    if fail==writes then ffi.copy(locate(a,#b),b,2);return false end
    ffi.copy(locate(a,#b),b,#b);return true
end
local state
local function reset()
    state={observed=0,protected=0,restored=0,startup_clears=0,short_ends=0,table_moves=0}
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
-- The Mod Options Menu slider raises the limit up to the standing reference,
-- 1.30, where the avatar swims (deeper water is 'deep_water' anyway). Values
-- outside 0.20-1.30 clamp; anything but a number is refused.
assert(patch.MIN_WATER_DEPTH==0.20 and patch.SWIM_DEPTH==1.30 and patch.max_water_depth==0.20)
for _,limit in ipairs({0.45,1.30}) do
    assert(patch.set_max_water_depth(limit))
    for _,depth in ipairs({0.1,0.21,0.44,0.45,0.46,0.8,1.29,1.31,1.6}) do
        reset();f(water,24,number(position,8)+depth)
        assert(apply());local allowed=depth<=limit and depth<1.30
        assert((state.protected==1)==allowed,'Incorrect depth boundary at limit '..limit..': '..depth)
        if allowed then assert(patch.restore(api,state.pending))else assert(writes==0)end
    end
end
reset();f(water,24,-0.9994804859161377);assert(apply());assert(state.protected==1,'60 cm water within a raised limit')
assert(patch.restore(api,state.pending))
assert(patch.set_max_water_depth(5) and patch.max_water_depth==1.30)
assert(patch.set_max_water_depth(0) and patch.max_water_depth==0.20)
assert(not patch.set_max_water_depth('deep') and not patch.set_max_water_depth(0/0) and patch.max_water_depth==0.20)
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
reset();change_guard={address=water_record,count=1,change=function() f(water,24,-0.8) end}
assert(apply());assert(writes==0)
-- Records that share one bulk read keep their own guards: a change to any of
-- them before the coherence check stops the acquisition too. The check reads
-- each record at its own address (count 0), except records that start a bulk
-- read, which the snapshot read there first (count 1).
for _,case in ipairs({
    {pm+0x3a8,0,function() u(players,0x3a8,10) end,function() end},
    {am+0x6c,1,function() u(avatars,0x6c,3) end,function() u(avatars,0x6c,2) end},
    {am+0x110+8,0,function() p(avatars,0x118,owner+0xf32f18+48) end,function() p(avatars,0x118,owner+0xf32f18+24) end},
    {am+local_ctl+0xf80,0,function() u(avatars,local_ctl+0xf8c,0x30) end,function() end},
    {dm+8,1,function() u(drown,8,3) end,function() u(drown,8,2) end},
    {dm+72,0,function() p(drown,72,0x53500008) end,function() p(drown,72,0x53500000) end},
    {sm+56,0,function() p(stances,56,0x53700008) end,function() p(stances,56,0x53700000) end},
    {mm+0x48d8,0,function() p(motion,0x48d8,0x53900008) end,function() p(motion,0x48d8,0x53900000) end},
    {0x54000000+122*16+5*64,0,function() f(resource,122*16+5*64+8,1) end,function() f(resource,122*16+5*64+8,0) end},
}) do
    reset();change_guard={address=case[1],count=case[2],change=case[3]}
    local ok,reason=apply();assert(ok and reason=='snapshot_changed' and writes==0,
        string.format('guard at %x: %s',case[1],tostring(reason)))
    case[4]()
end
-- The engine replacing the offset during a held lease ends the lease without
-- writing: its own value stays.
reset();assert(apply());local prior_writes=writes;f(water,8,-0.8)
local ok_offset,offset_reason=apply()
assert(ok_offset and offset_reason=='offset_changed_by_engine' and not state.pending and writes==prior_writes)
near(number(water,8),-0.8)
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
-- Idle gate: a full check follows a change of local avatar within 31 checks,
-- and the gate then watches the new avatar's controller.
do
    reset();u(avatars,local_ctl+0xf8c,0);assert(apply());assert(state.gate_controller==am+local_ctl)
    local other=0x53d900
    u(avatars,other+0xb84,111);u(rows_owner,9%16*8+4,0)
    for i=1,30 do local ok,reason=apply();assert(ok and reason=='dive_ended' and state.gate_controller==am+local_ctl) end
    assert(apply());assert(state.gate_controller==am+other and state.key==owner+0xf32f18)
    u(avatars,other+0xf8c,0x20);local ok,reason=apply()
    assert(ok and reason=='waiting_for_water_record' and not state.gate_controller and writes==0)
    u(avatars,other+0xf8c,0);u(avatars,other+0xb84,0);u(rows_owner,9%16*8+4,1)
    -- Anything unexpected at the controller goes to the full check, which
    -- stops the mod as before: another avatar id, or a non-finite timer.
    reset();u(avatars,local_ctl+0xf8c,0);assert(apply())
    u(avatars,local_ctl+0xb84,999);assert(not pcall(apply),'gate accepted another avatar id')
    u(avatars,local_ctl+0xb84,222)
    reset();u(avatars,local_ctl+0xf8c,0);assert(apply())
    f(avatars,local_ctl+0xb84+8,0/0);assert(not pcall(apply),'gate accepted a NaN dive timer')
end
print('PASS: idle gate reads one controller; a periodic full check follows a new local avatar')
-- Map lookups use the low 32 bits of key*mult as the game does. The fixture
-- maps use mult=1, so find the local entity through a 2^20-slot map (every
-- bit of the hash counts) with a unit id above 16 bits and real multipliers.
do
    local header,unit=locate(owner+0xf22ec8,20),0x12345
    for n,mult in ipairs({0x9e3779b1,0xffffffff,0x10001,0x7fffffff,3,0xdeadbeef}) do
        local slot=bit.band(tonumber(ffi.cast('uint32_t',ffi.new('uint64_t',unit)*mult)),0xfffff)
        local rows=0x56000000+n*0x1000000
        local row=region(rows+slot*8,8);u(row,0,unit);u(row,4,1)
        reset();u(players,0x3a8,unit);p(header,0,rows);u(header,8,0x100000);u(header,16,mult)
        assert(apply());assert(state.protected==1,string.format('mult %x',mult))
        assert(patch.restore(api,state.pending))
    end
    p(header,0,0x53000000);u(header,8,16);u(header,16,1)
end
print('PASS: hash lookups match 64-bit key*mult for real multipliers')
-- Compiled code must decode what the interpreter does: in a hot loop (the JIT
-- compiles apply's start and held paths) every lease survives its next check.
jit.on()
for i=1,300 do
    reset();assert(apply());local ok,reason=apply()
    assert(ok and reason=='airborne_reference' and state.pending,'lease lost in compiled code, iteration '..i)
    assert(patch.restore(api,state.pending))
end
print('PASS: 300 compiled dive starts keep their leases')
-- Per-check call budget. The loader checks before the game update, and after
-- it only while a local avatar exists or a lease or retry is in progress.
-- Outside a mission a check reads the mission record and stops. In a mission a
-- full check reads the identity chain (14 reads: records of one object share
-- one read) and the next 30 read only the local dive controller (1 read). A
-- dive start reads and validates everything, then writes the lease.
do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local counts=budget.wrap(api)
    local function check(label,limits,expected)
        local frame,ok,reason=budget.frame(counts,apply)
        assert(ok and reason==expected,label..': '..tostring(reason))
        budget.check(frame,limits,label)
    end
    reset();u(mission,8,0)
    check('outside a mission',{read=2},'waiting_for_mission')
    u(mission,8,1);reset();u(avatars,local_ctl+0xf8c,0)
    check('idle in a mission, full check',{read=14},'dive_ended')
    for i=1,30 do check('idle in a mission, gate '..i,{read=1},'dive_ended') end
    check('idle in a mission, periodic full check',{read=14},'dive_ended')
    check('idle in a mission, gate after it',{read=1},'dive_ended')
    u(avatars,local_ctl+0xf8c,0x20)
    -- The gate sees the dive and the full check runs at once. The session's
    -- first dive also verifies the game.dll constants, and the first dive in a
    -- water-record table checks its page: one protection query (about 0.25 ms
    -- in game) covers both writes.
    check('first dive start',{read=99,writable_data=1,write=2},'airborne_reference')
    check('dive held',{read=31},'airborne_reference')
    u(avatars,local_ctl+0xf8c,0)
    -- The landing write reuses its dive's page check.
    check('dive end',{read=49,write=1},'dive_ended')
    check('idle after a dive',{read=1},'dive_ended')
    f(water,16,0.011);u(avatars,local_ctl+0xf8c,0x20)
    -- Later dives in the same table reuse the kept check.
    check('later dive start',{read=94,write=2},'airborne_reference')
    -- A restore outside a normal landing (shutdown, a stop) checks again.
    local frame,restored=budget.frame(counts,patch.restore,api,state.pending)
    assert(restored and frame.writable_data==1 and frame.write==1,'restore at shutdown: '..budget.describe(frame))
    -- Page checks follow the table: kept across dives while the same Drownable
    -- manager, table and avatar are in use; dropped by any wait, avatar change,
    -- table move or failed write.
    local function queries(...) return budget.frame(counts,...).writable_data or 0 end
    local function dive(record)
        f(record,16,0.011);u(avatars,local_ctl+0xf8c,0x20)
        local n=queries(apply);assert(state.pending,'dive not assisted')
        u(avatars,local_ctl+0xf8c,0)
        n=n+queries(apply);assert(not state.pending,'lease not released')
        return n
    end
    reset();u(avatars,local_ctl+0xf8c,0);apply()
    assert(dive(water)==1 and dive(water)==0 and dive(water)==0,'one page check per table')
    -- The wait is seen by the next full check (the idle gate reads only the
    -- controller; a load spans many full checks).
    u(mission,8,0);state.gate_left=0;apply();u(mission,8,1);apply()
    assert(dive(water)==1,'a wait keeps the page check')
    u(entities,24+12,555);apply()
    assert(dive(water)==1,'an avatar change keeps the page check')
    u(entities,24+12,444);apply();assert(dive(water)==1)
    local moved=region(0x53480000,56);ffi.copy(moved,waters,56);tables[#tables+1]=0x53480000
    p(drown,64,0x53480000);apply()
    assert(dive(moved+28)==1 and state.table_moves==1 and dive(moved+28)==0,'a moved table keeps the page check')
    p(drown,64,0x53400000);apply();assert(dive(water)==1 and state.table_moves==2)
    -- A new Drownable manager object (same table) is checked again too.
    local manager=region(0x50100000,80);ffi.copy(manager,drown,80);p(locate(game+0x3326a80,8),0,0x50100000)
    assert(dive(water)==1 and state.table_moves==3,'a new manager keeps the page check')
    p(locate(game+0x3326a80,8),0,dm);apply();assert(dive(water)==1)
    -- A record outside the span the check approved is checked again.
    state.write_check.high=state.write_check.low+28+8
    assert(dive(water)==1,'a record outside the approved span was not checked')
    fail=writes+1;f(water,16,0.011);u(avatars,local_ctl+0xf8c,0x20)
    assert(not apply() and not state.write_check,'a failed write keeps the page check')
    -- A dive the mod does not assist (deep water here) is read in full on each
    -- check; the gate only runs again after it ends.
    reset();u(avatars,local_ctl+0xf8c,0);apply()
    f(water,24,1);u(avatars,local_ctl+0xf8c,0x20)
    check('unassisted dive start',{read=35},'deep_water')
    check('unassisted dive',{read=31},'deep_water')
    u(avatars,local_ctl+0xf8c,0)
    check('unassisted dive end',{read=14},'dive_ended')
    check('idle after an unassisted dive',{read=1},'dive_ended')
end
print('PASS: per-check call budget: 2 reads outside a mission, 1 read (gate) or 14 (every 31st check) idle in a mission, 31 per dive frame')
print('PASS: one protection query per water-record table: kept across dives and landings, redone after waits, avatar changes, table moves, failed writes and at shutdown')
-- Garbage per check with the JIT off (the interpreter is the worst case): no
-- state that repeats frame after frame may allocate.
do
    local function garbage(label,before_each)
        jit.off();jit.flush()
        before_each();apply()
        collectgarbage('collect');collectgarbage('stop')
        local start=collectgarbage('count')
        for _=1,100 do before_each();apply() end
        local bytes=(collectgarbage('count')-start)*1024
        collectgarbage('restart');jit.on()
        assert(bytes==0,label..': '..bytes..' bytes in 100 checks')
    end
    local nothing=function() end
    reset();u(mission,8,0);garbage('outside a mission',nothing);u(mission,8,1)
    reset();p(locate(game+0x33266a0,8),0,0);garbage('waiting for the mission manager',nothing)
    p(locate(game+0x33266a0,8),0,mode)
    reset();u(players,0x3a8,0x7fff);garbage('waiting for a local avatar',nothing)
    reset();u(avatars,local_ctl+0xf8c,0);garbage('idle, full check',function() state.gate_controller=nil end)
    reset();u(avatars,local_ctl+0xf8c,0);garbage('idle, gate',function() state.gate_left=30 end)
    reset();assert(apply() and state.pending);garbage('dive held',nothing)
    assert(patch.restore(api,state.pending))
end
print('PASS: no garbage outside a mission, while waiting, idle (full check and gate) or while a dive is held')
-- The whole per-frame path: the loader (archive_loader.lua) on the runtime's
-- update guard, over this patch and the fixture. A frame is one update: a
-- check before the game's update and, while a local avatar exists or a lease
-- or retry is in progress, one after it. The calls per frame are the checks'
-- own (the guard and the loader add none), and a frame allocates nothing.
-- Both Mod Options Menu paths: loader v18 (the bounded retry, which watches
-- all session here because no menu is installed) and a loader with the
-- after_startup capability (one registration before the first update).
for _,kind in ipairs({'retry','after_startup'}) do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local env=setmetatable({print=function() end},{__index=_G});env._G=env
    local queued={}
    env.CowboyBingusModLoader={api=1,version=6,open_log=function() end}
    if kind=='after_startup' then
        env.CowboyBingusModLoader={api=1,version=17,open_log=function() end,capabilities=setmetatable({},{__index={after_startup=true}}),
            after_startup=function(fn) queued[#queued+1]=fn;return true end}
    end
    env.update=function() end
    env.shutdown=function() end
    local frame_api={read=api.read,write=api.write,writable_data=api.writable_data,
        module=function(name) return name and game or 1 end,
        module_hash=function(module) return module==game and 'game' or 'exe' end}
    local counts=budget.wrap(frame_api)
    local Text=assert(loadfile(source..'/bingus_text.lua'))()
    local locales={en=assert(loadfile(source..'/../locales/en.lua'))(),bundled={}}
    local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
    setfenv(assert(loadfile(source..'/archive_loader.lua')),env)()(function() return frame_api end,patch,
        {revision='frame',game_sha256='game',exe_sha256='exe'},Text,locales,runtime)
    for _,fn in ipairs(queued) do fn() end
    local loaded=env.ShallowWaterDive
    assert(loaded.depth_option==(kind=='after_startup' and 'not installed' or nil),kind)
    local function frame(label,limits,expected)
        label=label..' ('..kind..')'
        local calls=budget.frame(counts,env.update,1/60)
        assert(loaded.status==expected,label..': '..tostring(loaded.status))
        budget.check(calls,limits,label)
        return calls
    end
    reset();u(mission,8,0)
    frame('outside a mission, first update',{read=2},'waiting_for_mission')
    frame('outside a mission',{read=2},'waiting_for_mission')
    -- 62 checks in 31 idle frames: 2 full checks (14 reads) and 60 gates (1 read).
    u(mission,8,1);u(avatars,local_ctl+0xf8c,0)
    local full=0
    for i=1,31 do
        local calls=frame('idle in a mission '..i,{read=15},'dive_ended')
        assert(calls.read==2 or calls.read==15,'idle frame '..i..': '..budget.describe(calls))
        if calls.read==15 then full=full+1 end
    end
    assert(full==2,'idle frames with a full check: '..full)
    -- A dive start and the held check after the update. The 31 idle frames
    -- used up the gate, so the dive frame starts with a full check (98 reads:
    -- the session's first dive verifies the game.dll constants; one page
    -- check), then 31 for the held check.
    u(avatars,local_ctl+0xf8c,0x20)
    frame('first dive start',{read=129,writable_data=1,write=2},'airborne_reference')
    frame('dive held',{read=62},'airborne_reference')
    u(avatars,local_ctl+0xf8c,0)
    frame('dive end',{read=50,write=1},'dive_ended')
    frame('idle after a dive',{read=2},'dive_ended')
    -- Garbage per frame with the JIT off (the interpreter is the worst case).
    local function garbage(label,setup)
        jit.off();jit.flush()
        setup();env.update(1/60)
        collectgarbage('collect');collectgarbage('stop')
        local start=collectgarbage('count')
        for _=1,100 do env.update(1/60) end
        local bytes=(collectgarbage('count')-start)*1024
        collectgarbage('restart');jit.on()
        assert(bytes==0,label..' ('..kind..'): '..bytes..' bytes in 100 frames')
    end
    garbage('guarded update outside a mission',function() u(mission,8,0) end)
    garbage('guarded update idle in a mission',function() u(mission,8,1);u(avatars,local_ctl+0xf8c,0) end)
    garbage('guarded update with a dive held',function() f(water,16,0.011);u(avatars,local_ctl+0xf8c,0x20) end)
    assert(loaded.status=='airborne_reference' and loaded.pending)
    -- Compiled (JIT on), once the traces have settled: recording a trace
    -- allocates, and the idle checks' traces settle within about 2000 frames
    -- here. One loop serves the warm-up and the windows, so the windows record
    -- nothing new. Every window of 100 frames then allocates nothing.
    local function frames(n) for _=1,n do env.update(1/60) end end
    local function compiled_garbage(label,setup)
        jit.on();jit.flush()
        setup();frames(3000)
        for window=1,3 do
            collectgarbage('collect');collectgarbage('stop')
            local start=collectgarbage('count')
            frames(100)
            local bytes=(collectgarbage('count')-start)*1024
            collectgarbage('restart')
            assert(bytes==0,label..' ('..kind..', compiled): '..bytes..' bytes in 100 frames, window '..window)
        end
    end
    u(avatars,local_ctl+0xf8c,0);env.update(1/60)
    compiled_garbage('guarded update outside a mission',function() u(mission,8,0) end)
    compiled_garbage('guarded update idle in a mission',function() u(mission,8,1);u(avatars,local_ctl+0xf8c,0) end)
    compiled_garbage('guarded update with a dive held',function() f(water,16,0.011);u(avatars,local_ctl+0xf8c,0x20) end)
    assert(loaded.status=='airborne_reference' and loaded.pending)
    u(avatars,local_ctl+0xf8c,0);env.update(1/60)
    assert(loaded.status=='dive_ended' and not loaded.pending and env.BingusRuntime.statuses.ShallowWaterDiving.errors==0)
    env.shutdown();assert(loaded.status=='stopped')
end
print('PASS: guarded update (loader on the runtime guard), with the menu retry and with after_startup: per frame only the checks\' calls (2 reads outside a mission, 2 or 15 idle, 62 with a dive held) and no garbage outside a mission, idle or with a dive held, interpreted or compiled')
-- Machine code in the LuaJIT cache the game and every mod share: idle and
-- held-dive checks (with this fixture) compile about 13 KB while the full
-- snapshot stays interpreted, about 50 KB if it is compiled.
do
    local util=require('jit.util')
    jit.flush()
    local traces={}
    jit.attach(function(what,tr) if what=='stop' then traces[#traces+1]=tr end end,'trace')
    reset();u(avatars,local_ctl+0xf8c,0)
    for _=1,3000 do apply() end
    u(avatars,local_ctl+0xf8c,0x20)
    for _=1,3000 do apply() end
    jit.attach(function() end,'trace')
    assert(state.pending and patch.restore(api,state.pending))
    local bytes=0
    for _,tr in ipairs(traces) do local code=util.tracemc(tr);if code then bytes=bytes+#code end end
    assert(bytes<32*1024,string.format('%.1f KB of machine code for idle and held checks',bytes/1024))
end
print('PASS: idle and held-dive checks compile under 32 KB of machine code')
-- The next free ID in the C type table every mod in the VM shares. A probe
-- struct itself takes two type IDs.
local function next_type() return tonumber(ffi.typeof('struct { int probe; }')) end
-- The Windows adapter, on Bingus Shared Runtime v1 passed in as the build does
-- (the core, and bingus_memory.lua's api extended by bingus_write.lua): reads
-- into a caller buffer without allocating, refuses ranges outside that buffer
-- and unreadable memory, and takes the same number addresses for string reads
-- and writes. It binds no Windows function under its plain name, so the
-- clashing declarations made at the top of this file (H.clash) change nothing.
do
    local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
    local function memory_api()
        return assert(loadfile(source..'/bingus_write.lua'))().extend(assert(loadfile(source..'/bingus_memory.lua'))().new(runtime))
    end
    local make=assert(loadfile(source..'/windows_api.lua'))()
    -- The adapter refuses a memory api without the write side (its own checked
    -- writes cast the runtime's WriteProcessMemory) and a missing runtime.
    assert(not pcall(make,runtime,assert(loadfile(source..'/bingus_memory.lua'))().new(runtime)),'memory api without writes')
    assert(not pcall(make,nil,memory_api()) and not pcall(make,runtime),'runtime and memory api required')
    local memory_used=memory_api()
    local win=make(runtime,memory_used)
    local memory=ffi.new('uint8_t[64]');for i=0,63 do memory[i]=i end
    local at=tonumber(ffi.cast('uintptr_t',memory))
    local data=ffi.new('uint8_t[32]')
    local into={data=data,address=tonumber(ffi.cast('uintptr_t',data)),size=32}
    assert(win.read(at+8,16,into,8)==true and data[8]==8 and data[23]==23 and data[24]==0 and data[7]==0)
    assert(win.read(at,16,into,17)==nil and win.read(at,0,into,0)==nil and win.read(at,4,into,-1)==nil)
    assert(win.read(0x10,4,into,0)==nil and win.read(0x10,4)==nil)
    assert(win.read(at+4,4)=='\4\5\6\7')
    assert(win.write(at+60,'\9\8\7\6') and memory[60]==9 and memory[63]==6)
    -- The page check approves the whole pages around the range and counts its
    -- queries; a write the caller vouches for (checked) makes none, any other
    -- write is checked by the runtime, and image memory is refused.
    local before=win.queries
    local ok,low,high=win.writable_data(at+8,12)
    assert(ok and low%4096==0 and high%4096==0 and low<=at+8 and at+20<=high and high-low<=8192,'page check span')
    assert(win.queries==before+1 and not win.writable_data(at,0) and win.queries==before+1)
    before=win.queries
    assert(win.write(at+56,'\1\2\3\4',true) and memory[56]==1 and win.queries==before)
    assert(win.write(at+56,'\5\6\7\8') and memory[56]==5 and win.queries==before+1)
    local image=tonumber(ffi.cast('uintptr_t',win.module(nil)))
    assert(not win.writable_data(image,8) and not win.write(image,'\0') and win.queries==before+3,'image memory')
    -- Module hashes come from the runtime: read once per session for every mod.
    local shared=runtime.shared()
    local hash=win.module_hash(win.module(nil))
    local reads=shared.hash_reads
    assert(#hash==64 and win.module_hash(win.module(nil))==hash and shared.hash_reads==reads,'session hash cache')
    -- The log throttle's clock is the runtime's own (no wrapper, nothing per call
    -- but QueryPerformanceCounter), in seconds like the GetTickCount64 / 1000 it
    -- replaces: both agree over at least 60 ms (the tick count moves in steps of
    -- about 16 ms).
    assert(win.time==memory_used.time and type(win.time())=='number' and win.time()>0)
    ffi.cdef('uint64_t swd_test_GetTickCount64(void) __asm__("GetTickCount64");')
    local tick=ffi.load('kernel32').swd_test_GetTickCount64
    local t0,k0=win.time(),tonumber(tick())
    while tonumber(tick())-k0<60 do end
    local seconds,ticks=win.time()-t0,(tonumber(tick())-k0)/1000
    assert(math.abs(seconds-ticks)<0.035,'time() in seconds: '..seconds..' s against '..ticks..' s of tick count')
    -- Buffer reads allocate nothing and a string read only its string: reading
    -- the same bytes again finds that string already interned. A page check
    -- allocates nothing either (the runtime takes number addresses without a
    -- pointer cast), so a dive start's check adds no garbage, and neither does
    -- the clock (the tick count it replaces boxed 16 B per call).
    jit.off();collectgarbage('collect');collectgarbage('stop')
    local start=collectgarbage('count')
    for _=1,100 do assert(win.read(at,32,into,0)) end
    for _=1,100 do assert(win.read(at+4,4)=='\4\5\6\7') end
    for _=1,100 do assert(win.writable_data(at+8,12)) end
    for _=1,100 do assert(win.time()>0) end
    local bytes=(collectgarbage('count')-start)*1024
    collectgarbage('restart');jit.on()
    assert(bytes==0,'Windows adapter: '..bytes..' bytes in 100 buffer reads, 100 string reads, 100 page checks and 100 clock reads')
    -- Its declarations and the runtime's are made once per process: creating
    -- the adapter again adds no C types to the table every mod shares.
    local first=next_type()
    for _=1,5 do assert(loadfile(source..'/windows_api.lua'))()(runtime,memory_api()) end
    local added=next_type()-first-2
    assert(added==0,'5 adapter creations added '..added..' C types')
end
print('PASS: Windows adapter on Bingus Shared Runtime v1 (core, memory and write files): works after another mod declared 19 Windows names (every one the runtime and the translation module bind, and the tick count) with wrong prototypes (H.clash), buffer reads without garbage and string reads allocating only their string, bad ranges and unreadable memory rejected, whole-page checks counted and allocation-free, image memory refused, module hashes once per session, the runtime\'s clock in seconds without garbage')
-- Loading the module again adds no C types to the table every mod in the VM
-- shares (the Megapack's loader test loads it thousands of times).
do
    local before=next_type()
    for _=1,20 do assert(loadfile(source..'/dive_data.lua'))() end
    local added=next_type()-before-2
    assert(added==0,'20 module loads added '..added..' C types')
end
print('PASS: repeated module loads add no C types')
print('PASS: dive timeout at the build 25480438 address, old-address fallback and located failure message')
print('PASS: 20 cm depth limit, no dry/reset-surface assistance, restoration above 20 cm, startup debt, landings, prone/ragdoll/timeout, local ownership and write failures')
print('PASS: null managers/player pointers, empty records and transient stance/motion wait then recover; invalid pointers and settings still fail')
