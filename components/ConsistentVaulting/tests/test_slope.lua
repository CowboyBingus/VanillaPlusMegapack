local source=assert(arg[1]);local ffi=require('ffi')
local A=assert(loadfile(source..'/slope_assist.lua'))()
local regions={}
local function region(a,n)
    local b=ffi.new('uint8_t[?]',n);regions[#regions+1]={a=a,n=n,b=b};return b
end
local function locate(a,n)
    for _,r in ipairs(regions) do if a>=r.a and a+n<=r.a+r.n then return r.b+a-r.a end end
    error(string.format('Unbounded fixture access %x + %x',a,n))
end
local function put(b,o,t,v)ffi.copy(b+o,ffi.new(t..'[1]',v),ffi.sizeof(t)) end
local function u(b,o,v)put(b,o,'uint32_t',v) end
local function p(b,o,v)put(b,o,'uint64_t',v) end
local function f(b,o,v)put(b,o,'float',v) end
local function number(a)return tonumber(ffi.cast('float *',locate(a,4))[0]) end
local g,e,pm,mode,owner,am,mm=0x10000000,0x20000000,0x30000000,0x31000000,0x40000000,0x50000000,0x60000000
for rva,address in pairs({[0x33266a0]=mode,[0x3326468]=pm,[0x346bf98]=owner,[0x3326d20]=am,[0x3326558]=mm}) do p(region(g+rva,8),0,address) end
local players,mission,avatars,movement=region(pm,0x440),region(mode,0x44),region(am,0x550000),region(mm,0x48e0)
local player=region(0x70000000,24);player[20]=1;p(players,0xe8,0x70000000)
u(players,0x84,2);u(players,0x88,2);u(players,0x3a8,9);u(mission,8,1);u(mission,0x40,1)
local function map(b,o,address,key,index)
    p(b,o,address);u(b,o+8,16);u(b,o+12,0xffffffff);u(b,o+16,1)
    local rows=region(address,128)
    for i=0,15 do u(rows,i*8,0xffffffff) end
    u(rows,key%16*8,key);u(rows,key%16*8+4,index);return rows
end
local unitmap=region(owner+0xf22ec8,20)
map(unitmap,0,0x70100000,9,1)
local entities=region(owner+0xf32f18,48)
for i=0,1 do
    ffi.copy(entities+i*24,'\151\250\077\041\077\051\028\077',8)
    u(entities,i*24+8,i==0 and 111 or 222);u(entities,i*24+12,i==0 and 333 or 444);entities[i*24+20]=1
    p(avatars,0x110+i*8,owner+0xf32f18+i*24)
end
local avatarrows=map(avatars,0xf8,0x70200000,222,1)
u(avatarrows,111%16*8,111);u(avatarrows,111%16*8+4,0);u(avatars,0x6c,2)
local overrides=map(avatars,0x547c70,0x70300000,222,1)
map(movement,0x48a0,0x70400000,222,0)
local move,mover=region(0x70500000,132),region(0x70600000,164)
p(movement,0x48c8,0x70500000);p(movement,0x48d0,0x70600000);u(mover,76,123);u(mover,88,0x80000001)
local pool=region(0x70700000,56);p(region(e+0x27c3298+2*0x810,8),0,0x70700000)
local records=region(0x70800000,128);p(pool,0,0x70800000);u(pool,28,0x00000040)
u(pool,36,2);u(pool,40,0xffff);u(pool,52,0x80000000)
u(records,64,0x80000001);u(records,72,444);p(records,80,0x70900000);p(records,88,0x70a00000)
local definition,object=region(0x70900000,28),region(0x70a00000,104)
u(definition,0,123);f(definition,8,1.9);f(definition,12,.5);f(definition,16,.5)
f(definition,20,50*math.pi/180);f(definition,24,70*math.pi/180)
p(object,0,e+0x16a16d8);f(object,88,1);f(object,100,math.cos(70*math.pi/180))
local component=region(0x70b00000,884);p(region(owner+0xf12bb8,8),0,0x70b00000)
ffi.copy(component,entities+24,8);u(component,8,0)
local settings=avatars+0x547d24+852
local input=0x150+0xa7aec+0x1b68+14*32
local direction=0x53e134+0x1238
local flags=0x53e880+0x1238
local cells={cap=am+direction+8,enter=am+0x547d24+852+152,exit=am+0x547d24+852+172,slope=0x70a00000+96,height=am+0x547d24+852+260}
u(avatars,direction+40,222);u(avatars,0x53e1b8+0x1238+0x2ac,222)
local now,position,writes,override_calls,fail,partial,unreadable,release_on_write=0,{0,0,0},0,0
local native={mover_position=function(unit,name)assert(unit==444 and name==123);return {unpack(position)} end}
local api={time=function()return now end,distance=function(a,b)return a-b end,native=function()return native end}
function api.read(a,n)if a==unreadable then return nil end;return ffi.string(locate(a,n),n) end
function api.pointer(b,o)
    if not b then return nil end
    local v=ffi.new('uint64_t[1]');ffi.copy(v,b:sub((o or 0)+1),8)
    local n=tonumber(v[0]);if n>=0x10000 then return n end
end
function api.writable_data(a,n)
    if n~=4 then return false end
    for _,address in pairs(cells) do if a==address then return true end end
    return false
end
function api.write(a,b)
    assert(api.writable_data(a,#b),'Write escaped four local fields');writes=writes+1
    if release_on_write==writes then avatars[input]=0 end
    if fail==writes then return false end
    if partial==writes then ffi.copy(locate(a,4),b,2);return false end
    ffi.copy(locate(a,4),b,4);return true
end
function native.ensure_override(manager,entity)
    assert(manager==am and entity==owner+0xf32f18+24)
    override_calls=override_calls+1
    -- Model the original zero-count modifier: unchanged copy and local mapping.
    ffi.copy(settings,component+32,852)
    u(overrides,222%16*8,222);u(overrides,222%16*8+4,1);u(avatars,0x547d20,2)
end
local candidate_kind='slope'
local function reset()
    candidate_kind='slope';A.candidate=function()return candidate_kind,'fixture_candidate' end
    now=0;position={0,0,0};writes=0;override_calls=0;fail=nil;partial=nil;unreadable=nil;release_on_write=nil
    u(mission,0x40,1);u(players,0x3a8,9);avatars[input]=0
    ffi.fill(avatars+flags,24);u(avatars,flags,2);move[12]=0;move[15]=0;f(move,20,0);f(move,24,0);f(move,28,1)
    f(avatars,direction+8,-1);f(settings,12,2);f(settings,152,45);f(settings,172,40);f(settings,260,1.95)
    f(component+32,12,2);f(component+32,152,45);f(component+32,172,40);f(component+32,260,1.95)
    f(object,96,math.cos(50*math.pi/180));p(object,0,e+0x16a16d8)
    u(overrides,222%16*8,222);u(overrides,222%16*8+4,1);u(avatars,0x547d20,2)
    u(records,64,0x80000001);u(records,72,444);u(entities,32,222)
end
local passed=0
local remote=ffi.string(avatars+0x53e134,0x1238)
local definition_before=ffi.string(definition,28)
local function done()
    assert(ffi.string(avatars+0x53e134,0x1238)==remote,'Other avatar changed')
    assert(ffi.string(definition,28)==definition_before,'Shared mover definition changed')
    assert(number(0x70b00000+32+152)==45,'Shared settings changed')
    passed=passed+1
end
local function step(s)local ok,why=A.step(api,g,e,s);assert(ok,why) end
local function arm(s)step(s);avatars[input]=1;step(s);assert(s.slope_lease,'Lease not armed') end
local function baseline()
    assert(number(cells.enter)==45 and number(cells.exit)==40 and number(cells.cap)==-1)
    assert(math.abs(number(cells.slope)-math.cos(50*math.pi/180))<.000001)
    assert(math.abs(number(cells.height)-1.95)<.000001)
end
for mode=1,7 do
    reset();u(mission,0x40,mode);local state={};arm(state);assert(A.stop(api,g,e,state));baseline();done()
end
for _,mode in ipairs({0,8,0xffffffff})do
    reset();u(mission,0x40,mode);local state={};step(state);avatars[input]=1;step(state)
    assert(not state.slope_lease and writes==0);done()
end
reset();u(mission,0x40,2);u(mission,8,0);local outside={};step(outside);avatars[input]=1;step(outside)
assert(not outside.slope_lease and writes==0);u(mission,8,1)
reset();local state={};step(state);assert(writes==0);done()
reset();state={};avatars[input]=1;step(state);assert(not state.slope_lease and writes==0);done()
reset();state={};arm(state)
assert(number(cells.enter)==65 and number(cells.exit)==60 and number(cells.cap)==-1,'Attempt slowed movement')
assert(math.abs(number(cells.slope)-math.cos(65*math.pi/180))<.000001 and state.slope_arms==1)
assert(A.stop(api,g,e,state));baseline();done()
reset();state={};arm(state);now=1.26;step(state);assert(not state.slope_lease);baseline()
now=2;step(state);assert(state.slope_arms==1,'Held input rearmed expired lease')
avatars[input]=0;step(state);avatars[input]=1;step(state);assert(state.slope_arms==2);assert(A.stop(api,g,e,state));done()
reset();state={};arm(state);u(avatars,flags+12,0x200);now=.5;step(state);assert(state.slope_climbs==1 and number(cells.cap)==2)
u(avatars,flags+12,0);f(move,20,math.sin(62*math.pi/180));f(move,28,math.cos(62*math.pi/180));now=1;position={0,1,1};step(state)
assert(state.slope_status=='support' and state.slope_landings==1)
now=300;step(state);assert(state.slope_lease,'Stable perch dropped on timer')
f(move,20,0);f(move,28,1);step(state);now=300.36;step(state);assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);u(avatars,flags+12,0x200);now=.5;step(state)
u(avatars,flags+12,0);f(move,20,math.sin(66*math.pi/180));f(move,28,math.cos(66*math.pi/180));now=1;step(state)
now=1.26;step(state);assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);position={3.01,0,0};step(state);assert(state.slope_last_release=='left_area');baseline();done()
reset();state={};arm(state);position={0,0,3.01};step(state);assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);u(avatars,flags+12,0x200);now=9;step(state);assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);u(avatars,flags,0x4002);step(state);assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);u(mission,0x40,0);step(state);assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);u(players,0x3a8,0x7fff);step(state);assert(not state.slope_lease);baseline();done()
reset();state={};f(avatars,direction+8,.75);arm(state);assert(number(cells.cap)==.75);assert(A.stop(api,g,e,state));assert(number(cells.cap)==.75);done()
reset();state={};arm(state);u(avatars,flags+12,0x200);step(state);f(avatars,direction+8,.25);step(state)
assert(not state.slope_lease and number(cells.cap)==.25 and number(cells.enter)==45);done()
reset();state={};f(settings,152,55);step(state);avatars[input]=1;step(state);assert(not state.slope_lease and writes==0);done()
reset();state={};u(overrides,222%16*8,0xffffffff);u(avatars,0x547d20,0);arm(state)
assert(override_calls==1 and state.slope_overrides==1);assert(A.stop(api,g,e,state));baseline();done()
reset();state={};u(overrides,222%16*8,0xffffffff);u(avatars,0x547d20,8);step(state);avatars[input]=1;step(state)
assert(override_calls==0 and writes==0 and not state.slope_lease);done()
reset();state={};p(object,0,e+0x16a5010);step(state);avatars[input]=1;step(state);assert(writes==0);done()
reset();state={};u(records,72,333);step(state);avatars[input]=1;step(state);assert(writes==0);done()
reset();state={};u(records,64,0x80000002);step(state);avatars[input]=1;step(state);assert(writes==0);done()
for failed=1,3 do
    reset();state={};step(state);avatars[input]=1;fail=failed
    local ok=A.step(api,g,e,state);assert(not ok and not state.slope_lease);baseline();done()
end
for failed=1,3 do
    reset();state={};step(state);avatars[input]=1;partial=failed
    local ok=A.step(api,g,e,state);assert(not ok and not state.slope_lease);baseline();done()
end
reset();state={};arm(state);unreadable=cells.slope;assert(not A.stop(api,g,e,state) and state.slope_lease)
unreadable=nil;assert(A.stop(api,g,e,state));baseline();done()
reset();state={};step(state);avatars[input]=1;release_on_write=3;step(state)
assert(not state.slope_lease);baseline();done()
reset();state={};arm(state);u(avatars,flags+12,0x200);step(state)
u(avatars,flags+12,0);move[12]=1;step(state);now=.26;step(state)
assert(not state.slope_lease,'Stale ground normal extended unsupported lease');baseline();done()
reset();state={};arm(state);u(entities,32,999);local before=writes
assert(A.stop(api,g,e,state) and writes==before,'Cleanup wrote into reused entity');done()
-- Regression: open-space input and failed candidate searches have zero writes,
-- including no native override creation and no temporary speed restriction.
reset();state={};candidate_kind=nil
u(overrides,222%16*8,0xffffffff);u(avatars,0x547d20,0)
step(state)
for i=1,5 do avatars[input]=1;now=i*2;step(state);avatars[input]=0;step(state) end
assert(writes==0 and override_calls==0 and not state.slope_lease);baseline();done()
reset();state={};candidate_kind=nil;step(state);avatars[input]=1;step(state)
now=.15;candidate_kind='slope';step(state);assert(state.slope_lease and number(cells.cap)==-1)
assert(A.stop(api,g,e,state));baseline();done()
reset();state={};candidate_kind=nil;step(state);avatars[input]=1;step(state)
now=1.3;candidate_kind='slope';step(state);assert(writes==0 and not state.slope_lease);done()
reset();state={};A.candidate=nil;step(state);avatars[input]=1;step(state)
assert(writes==0 and not state.slope_lease);done()
-- Cap writes are independently reversible after an actual native climb starts.
for _,mode in ipairs({'fail','partial'}) do
    reset();state={};arm(state);u(avatars,flags+12,0x200)
    if mode=='fail' then fail=writes+1 else partial=writes+1 end
    local ok=A.step(api,g,e,state);assert(not ok and not state.slope_lease);baseline();done()
end
-- Ledge search changes only the private ground-height allowance, never speed
-- or slope support. It ends as soon as its observed native climb finishes.
reset();state={};candidate_kind='ledge';arm(state)
assert(number(cells.height)==2.5 and number(cells.enter)==45 and number(cells.cap)==-1 and writes==1)
u(avatars,flags+12,0x200);step(state);step(state);assert(number(cells.cap)==-1 and state.ledge_climbs==1)
u(avatars,flags+12,0);step(state);assert(not state.slope_lease and state.ledge_arms==1);baseline();done()
reset();state={};candidate_kind='ledge';arm(state);now=1.3;step(state)
assert(state.ledge_attempt_expiries==1 and not state.ledge_climbs and not state.slope_lease)
baseline();done()
reset();state={};candidate_kind='ledge';f(settings,260,2);step(state);avatars[input]=1;step(state)
assert(writes==0 and not state.slope_lease);done()
reset();state={};candidate_kind='ledge';move[12]=1;step(state);avatars[input]=1;step(state)
assert(writes==0 and not state.slope_lease);done()

-- Relocation of the same entity's override must restore its new row.
reset();state={};arm(state);local old_enter,old_exit=cells.enter,cells.exit
ffi.copy(avatars+0x547d24+2*852,settings,852);u(overrides,222%16*8+4,2)
cells.enter=cells.enter+852;cells.exit=cells.exit+852
assert(A.stop(api,g,e,state) and number(cells.enter)==45 and number(cells.exit)==40)
cells.enter=old_enter;cells.exit=old_exit;done()
-- The main module applies assistance before reading the vault threshold and
-- its unified stop restores both systems on loader failures/shutdown.
reset();state={};local patch=assert(loadfile(source..'/vault_data.lua'))();patch.assistance=A
patch.snapshot=function()
    if state.slope_lease then assert(number(cells.enter)==65) end
    return nil,'fixture'
end
assert(patch.apply(api,g,e,state));avatars[input]=1;assert(patch.apply(api,g,e,state))
assert(state.slope_lease and patch.stop(api,g,e,state));baseline();done()
print('PASS: '..passed..' slope ownership, native-override model, limits, lease lifecycle, cleanup and integration scenarios')
