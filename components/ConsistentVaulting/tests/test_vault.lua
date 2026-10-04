local source=assert(arg[1])
local ffi=require('ffi')
local patch=assert(loadfile(source..'/vault_data.lua'))()
local regions={}
local function region(address,size)
    local data=ffi.new('uint8_t[?]',size)
    regions[#regions+1]={address=address,size=size,data=data}
    return data
end
local function put(data,o,kind,v) ffi.copy(data+o,ffi.new(kind..'[1]',v),ffi.sizeof(kind)) end
local function u(data,o,v) put(data,o,'uint32_t',v) end
local function p(data,o,v) put(data,o,'uint64_t',v) end
local function f(data,o,v) put(data,o,'float',v) end
local function vector(data,o,x,y,z) f(data,o,x);f(data,o+4,y);f(data,o+8,z) end
local function locate(address,size)
    for _,r in ipairs(regions) do
        if address>=r.address and address+size<=r.address+r.size then return r.data+address-r.address end
    end
    error(string.format('Unbounded fixture read %x + %x',address,size))
end
local game,exe,pm,mode,owner,manager,scheduler,movement,camera=
    0x10000000,0x20000000,0x30000000,0x31000000,0x40000000,0x50000000,0x60000000,0x70000000,0x71000000
local player_address=0x32000000
local globals={}
for _,rva in ipairs({0x33266a0,0x3326468,0x346bf98,0x3326d20,0x3326558,0x346d560}) do globals[rva]=region(game+rva,8) end
p(globals[0x33266a0],0,mode);p(globals[0x3326468],0,pm);p(globals[0x346bf98],0,owner)
p(globals[0x3326d20],0,manager);p(globals[0x3326558],0,movement);p(globals[0x346d560],0,camera)
local players,mission,player=region(pm,0x440),region(mode,0x44),region(player_address,24)
local avatars=region(manager,0x550000)
local queries=region(scheduler,0x40070)
local mv=region(movement,0x48e0)
local cam=region(camera,0x40)
local unitmap=region(owner+0xf22ec8,20)
local entities=region(owner+0xf32f18,48)
local function map(header,o,address,key,index)
    p(header,o,address);u(header,o+8,16);u(header,o+12,0xffffffff);u(header,o+16,1)
    local rows=region(address,128)
    for i=0,15 do u(rows,8*i,0xffffffff) end
    u(rows,key%16*8,key);u(rows,key%16*8+4,index)
    return rows
end
local unitrows=map(unitmap,0,0x72000000,9,1)
local avatarrows=map(avatars,0xf8,0x72100000,222,1)
u(avatarrows,111%16*8,111);u(avatarrows,111%16*8+4,0)
local overrides=map(avatars,0x547c70,0x72200000,222,1)
map(mv,0x48a0,0x72300000,222,0)
local move=region(0x72400000,132);local mover=region(0x72500000,164)
p(mv,0x48c8,0x72400000);p(mv,0x48d0,0x72500000);u(mover,76,123)
u(mission,8,1);u(mission,0x40,1);u(players,0x84,2);u(players,0x88,2)
p(players,0xe8,player_address);u(players,0x3a8,9);player[20]=1
for i=0,1 do
    ffi.copy(entities+i*24,'\151\250\077\041\077\051\028\077',8)
    u(entities,i*24+8,i==0 and 111 or 222);u(entities,i*24+12,i==0 and 333 or 444);entities[i*24+20]=1
    p(avatars,0x110+i*8,owner+0xf32f18+i*24)
end
u(avatars,0x6c,2);p(avatars,0x28,scheduler)
local local_offset=0x53e1b8+0x1238
local controller=manager+local_offset
local control=avatars+local_offset
local remote=avatars+0x53e1b8
u(control,0x2ac,222);u(remote,0x2ac,111)
local input_offset=0x150+0xa7aec+0x1b68+14*32
avatars[input_offset]=1
local settings=avatars+0x547d24+0x354
f(settings,0x98,45);f(settings,0x104,1.95);f(settings,0x108,1.4)
f(settings,0x10c,.6)
local component_pointer=region(owner+0xf12bb8,8)
local component=region(0x72600000,1736);p(component_pointer,0,0x72600000)
ffi.copy(component,entities+24,8);u(component,8,0)
f(component+32,0x98,45);f(component+32,0x104,1.95);f(component+32,0x108,1.4)
vector(cam,0x1c,0,1,0)
local actor_flags,actor_speed,exit_calls={},{},0
local native={
    mover_position=function(unit,name)assert(unit==444 and name==123);return {0,0,0} end,
    actor=function(id)
        if id==0xffffffff then return {valid=false} end
        return {valid=true,flags=actor_flags[id] or 0,motion_squared=actor_speed[id] or 0}
    end,
    exit=function(entity,target,direction)
        assert(entity==owner+0xf32f18+24 and direction[2]==1)
        exit_calls=exit_calls+1
        return target[1]==13 and 5 or 3
    end,
}
local writes,fail_write,partial_write,unreadable,changed_before_write=0,nil,nil,nil,nil
local api={native=function(g,e)assert(g==game and e==exe);return native end,distance=function(a,b)return a-b end}
api.read=function(address,size)
    if unreadable==address then return nil end
    return ffi.string(locate(address,size),size)
end
-- Into a caller buffer, like the runtime's read_into (byte by byte, so the
-- fixture itself allocates nothing either).
api.read_into=function(address,size,buffer)
    if unreadable==address then return false end
    local data=locate(address,size)
    for i=0,size-1 do buffer[i]=data[i] end
    return true
end
api.pointer=function(bytes,offset)
    if not bytes then return nil end
    local v=ffi.new('uint64_t[1]');ffi.copy(v,bytes:sub((offset or 0)+1),8)
    local n=tonumber(v[0]);if n<0x10000 or n>=0x800000000000 then return nil end
    return n
end
-- Protection is modeled per region, as one VirtualQuery answers for a whole
-- region: any span inside the local controller is writable. Each stored write
-- must still land on a local query unit/actor pair.
local function controller_span(address,size)
    return size>0 and address>=controller and address+size<=controller+0x2b0
end
api.writable_data=controller_span
local function store(address,bytes)
    assert(#bytes==8 and address>=controller+0x4c and address<=controller+0x4c+9*44
        and (address-controller-0x4c)%44==0,'Write escaped local query metadata')
    writes=writes+1
    if writes==changed_before_write then u(control,0x2ac,999);return false end
    if writes==partial_write then ffi.copy(locate(address,8),bytes,2);return false end
    if writes==fail_write then return false end
    ffi.copy(locate(address,8),bytes,8);return true
end
-- Like the Windows adapter: one protection query per write or per batch.
api.write=function(address,bytes)
    if not api.writable_data(address,#bytes) then return false end
    return store(address,bytes)
end
api.write_batch=function(base,size,changes)
    if not api.writable_data(base,size) then return false,0 end
    for i,change in ipairs(changes) do
        if change[1]<0 or change[1]+#change[2]>size or not store(base+change[1],change[2]) then return false,i-1 end
    end
    return true,#changes
end
local function read32(address)
    local v=ffi.new('uint32_t[1]');ffi.copy(v,api.read(address,4),4);return tonumber(v[0])
end
local function reset(hits)
    ffi.fill(control,0x2b0);u(control,0x2ac,222);u(control,4,2)
    ffi.fill(queries,0x40070);u(queries,0x40000,10)
    u(queries,0x40004,0);u(queries,0x40008,10);u(queries,0x4000c,1)
    for i=1,7 do u(queries,0x4000c+12*i,1) end
    for slot=0,9 do
        u(control,8+slot*4,slot+1)
        local q=queries+slot*128
        p(q,0,controller+0x30+slot*44);u(q,0x68,0x05a5271a);u(q,0x70,444)
        f(q,16,1);f(q,36,1);f(q,56,1);vector(q,80,.25,.03,.05)
        put(q,0x74,'uint16_t',1);q[0x7a]=2;q[0x7b]=1;q[0x7c]=5
        if hits[slot+1] then
            local h=hits[slot+1];local data=control+0x30+slot*44
            put(q,0x76,'uint16_t',1)
            vector(data,0,h.x or 0,0,h.height or 1)
            vector(data,12,0,0,h.normal or 1)
            u(data,28,444);u(data,32,h.actor or 1)
        end
    end
    avatars[input_offset]=1;move[15]=0;u(mission,0x40,1)
    actor_flags={};actor_speed={};writes=0;exit_calls=0
    fail_write=nil;partial_write=nil;unreadable=nil;changed_before_write=nil
end
local function run(state)
    local ok,reason=patch.apply(api,game,exe,state)
    assert(ok,reason);return reason
end
local remote_before=ffi.string(remote,0x1238)
local passed=0
local function done() assert(ffi.string(remote,0x1238)==remote_before,'Remote controller changed');passed=passed+1 end
for mode=1,7 do
    reset({{actor=2},{}});actor_flags[2]=0x100000;u(mission,0x40,mode)
    local state={};run(state);assert(state.pending,'vault rejected mission mode '..mode);done()
end
for _,mode in ipairs({0,8,0xffffffff})do
    reset({{actor=2},{}});actor_flags[2]=0x100000;u(mission,0x40,mode);run({});assert(writes==0);done()
end
reset({{actor=2},{}});actor_flags[2]=0x100000;u(mission,0x40,2);u(mission,8,0);run({});assert(writes==0);u(mission,8,1)

reset({{},{actor=2}});local state={};run(state);assert(writes==0,'Working first candidate changed');done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state)
assert(state.pending and read32(controller+0x4c)==0 and read32(controller+0x4c+44)==444)
assert(state.metadata_fallbacks==nil and actor_flags[2]==0x100000);done()
avatars[input_offset]=0;run(state);assert(read32(controller+0x4c)==444 and state.pending==nil);done()
reset({{actor=2}});actor_flags[2]=0x100000;state={};run(state)
assert(state.metadata_fallbacks==1 and read32(controller+0x50)==0xffffffff)
assert(actor_flags[2]==0x100000);done()
reset({{actor=2}});actor_flags[2]=0x100000;avatars[input_offset]=0;run({});assert(writes==0 and exit_calls==0);done()
reset({{actor=2}});actor_flags[2]=0x200000;run({});assert(writes==0);done()
reset({{actor=2},{}});actor_speed[2]=1.01;run({});assert(read32(controller+0x4c)==0);done()
reset({{actor=2}});actor_speed[2]=1;run({});assert(writes==0);done()
reset({{height=2},{}});run({});assert(read32(controller+0x4c)==0);done()
reset({{height=1.6},{height=1.2}});move[15]=1;run({});assert(read32(controller+0x4c)==0);done()
reset({{x=13},{}});run({});assert(read32(controller+0x4c)==0 and exit_calls==2);done()
reset({{x=13,actor=2}});actor_flags[2]=0x100000;run({});assert(writes==0);done()
reset({{normal=0.5},{}});run({});assert(read32(controller+0x4c)==0);done()
reset({{normal=0.5}});run({});assert(writes==0);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;u(queries,0x4000c,0)
assert(run({})=='waiting_for_query_workers' and writes==0);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;p(queries,0,manager+0x53e1b8+0x30)
assert(run({}):find('waiting_for_game_data',1,true) and writes==0);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;u(control,0x2ac,111)
assert(run({}):find('waiting_for_game_data',1,true) and writes==0);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;unreadable=pm+0xe8;state={}
run(state);assert(writes==0);unreadable=nil;run(state);assert(state.pending);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;u(mission,0x40,0)
assert(run({})=='waiting_for_mission' and writes==0);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state)
u(control,4,3);local old_writes=writes;run(state);assert(writes==old_writes and not state.pending);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state)
u(control,8,20);old_writes=writes;patch.restore(api,state.pending);assert(writes==old_writes);done()
reset({{actor=2},{actor=2},{}});actor_flags[2]=0x100000;fail_write=2;state={}
local ok,reason=patch.apply(api,game,exe,state)
assert(not ok and reason=='query_write_failed' and read32(controller+0x4c)==444 and read32(controller+0x4c+44)==444);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;partial_write=1;state={}
ok,reason=patch.apply(api,game,exe,state)
assert(not ok and reason=='query_write_failed' and read32(controller+0x4c)==444);done()
-- A write that lands in part can leave a byte mix of the original and the new
-- bytes: it is undone before the rollback.
reset({{actor=2},{}});actor_flags[2]=0x100000;u(control,0x30+28,0x12345678);partial_write=1;state={}
ok,reason=patch.apply(api,game,exe,state)
assert(not ok and reason=='query_write_failed' and read32(controller+0x4c)==0x12345678 and writes==2);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={}
local original_exit=native.exit
native.exit=function(...)local result=original_exit(...);avatars[input_offset]=0;return result end
run(state);assert(writes==0);native.exit=original_exit;done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state)
local before=writes;u(control,0x2ac,999);patch.restore(api,state.pending);assert(writes==before);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;actor_speed[2]=0/0
ok,reason=patch.apply(api,game,exe,{});assert(not ok and writes==0 and reason:find('validation_failed',1,true));done()
reset({{actor=2},{}});actor_flags[2]=0x100000;u(overrides,222%16*8,0xffffffff)
run({});assert(read32(controller+0x4c)==0);u(overrides,222%16*8,222);done()
reset({{actor=2}});actor_flags[2]=0x100000;avatars[input_offset]=3
run({});assert(read32(controller+0x50)==0xffffffff);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;entities[24]=0
run({});assert(writes==0);entities[24]=151;done()
-- A held vault keeps its prepared write while each check would prepare the
-- same one (no restore, no new write). A changed plan restores and prepares the
-- new one in the same check; a pair the game replaced is never restored.
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state)
local prepared_writes=writes
for _=1,3 do
    assert(run(state)=='local_manual_alternative_prepared' and writes==prepared_writes and state.pending)
    assert(read32(controller+0x4c)==0 and read32(controller+0x4c+44)==444)
end
actor_flags[2]=0
assert(run(state)=='native_vault_checks_retained' and read32(controller+0x4c)==444 and not state.pending);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state);actor_speed[1]=2
assert(run(state)=='local_manual_metadata_fallback_prepared' and writes==3)
assert(read32(controller+0x4c)==444 and read32(controller+0x50)==0xffffffff and state.metadata_fallbacks==1);done()
reset({{actor=2},{}});actor_flags[2]=0x100000;state={};run(state);u(control,0x30+28,555)
assert(run(state)=='local_manual_alternative_prepared' and writes==2 and read32(controller+0x4c)==0);done()

-- Reproduce the observed lifecycle: Lua sees consumed stage 3 and count zero,
-- although this avatar's descriptors/result counts remain in the scheduler.
local world_pointer=region(game+0x346bfa0,8);p(world_pointer,0,0x73000000)
local flags_offset=0x53e880+0x1238
local now,retries,refreshes,refresh_miss,retry_reject=10,0,0,false,false
api.time=function()return now end
native.context_matches=function(bytes)assert(#bytes==0x2b0);return true end
native.refresh_query=function(record,world)
    assert(world==0x73000000)
    refreshes=refreshes+1
    local address=assert(api.pointer(record))
    assert(address>=controller+0x30 and address<=controller+0x30+9*44)
    return api.read(address,44),refresh_miss and 0 or 1
end
native.retry=function(address)
    assert(address==controller and read32(controller+4)==2)
    assert(read32(scheduler+0x40000)==0,'Retry modified scheduler count')
    retries=retries+1
    u(control,4,3)
    if not retry_reject then u(avatars,flags_offset+12,0x200) end
end
-- The late retry may also write the phase and whole 44-byte hits.
store=function(address,bytes)
    local size=#bytes
    assert(address==controller+4 and size==4
        or size==44 and address>=controller+0x30 and address<=controller+0x30+9*44
            and (address-controller-0x30)%44==0
        or size==8 and address>=controller+0x4c and address<=controller+0x4c+9*44
            and (address-controller-0x4c)%44==0,'Late retry escaped local controller')
    writes=writes+1
    if writes==partial_write then ffi.copy(locate(address,#bytes),bytes,math.min(2,#bytes));return false end
    if writes==fail_write then return false end
    ffi.copy(locate(address,#bytes),bytes,#bytes);return true
end
local function late(hits)
    reset(hits);ffi.fill(avatars+flags_offset,24);u(avatars,flags_offset,2)
    u(control,4,3);u(queries,0x40000,0)
    now=now+1;retries=0;refreshes=0;refresh_miss=false;retry_reject=false
end
late({{actor=2},{}});actor_flags[2]=0x100000;state={}
local hits_before=api.read(controller+0x30,440);local scheduler_before=api.read(scheduler,1280)
assert(run(state)=='native_local_vault_started' and retries==1 and refreshes==2 and state.native_starts==1)
assert(api.read(controller+0x30,440)==hits_before and read32(controller+4)==3 and state.pending==nil)
assert(api.read(scheduler,1280)==scheduler_before and actor_flags[2]==0x100000);done()
late({{actor=2}});actor_flags[2]=0x100000;state={};run(state)
assert(state.metadata_fallbacks==1 and retries==1 and read32(controller+0x50)==2);done()
late({{actor=2}});actor_flags[2]=0x100000;refresh_miss=true;state={};run(state)
assert(refreshes==1 and retries==0 and writes==0 and not state.native_starts);done()
late({{x=13,actor=2}});actor_flags[2]=0x100000;state={};run(state)
assert(retries==0 and writes==0);done()
late({{height=3,actor=2}});actor_flags[2]=0x100000;run({});assert(retries==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;u(queries,0x40000,1)
assert(run({})=='waiting_for_idle_query_scheduler' and refreshes==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;u(queries,0x4000c,0)
assert(run({})=='waiting_for_query_workers' and refreshes==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;avatars[input_offset]=0;run({})
assert(refreshes==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;u(avatars,flags_offset+12,0x200);run({})
assert(refreshes==0 and retries==0);done()
late({{actor=2}});actor_flags[2]=0x100000;u(avatars,flags_offset,0);run({})
assert(refreshes==0 and retries==0);done()
late({{actor=2}});actor_flags[2]=0x100000;control[0x214]=1;run({})
assert(refreshes==0 and retries==0);done()
late({{actor=2}});actor_flags[2]=0x100000;f(queries,64,20)
assert(run({})=='retained_query_out_of_reach' and refreshes==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000
local context_matches=native.context_matches;native.context_matches=function()return false end
assert(run({})=='native_approach_changed_or_blocked' and refreshes==0 and retries==0 and writes==0)
native.context_matches=context_matches;done()
late({{actor=2}});actor_flags[2]=0x100000;retry_reject=true;state={}
assert(run(state)=='native_local_retry_rejected' and retries==1 and not state.native_starts)
assert(run(state)=='waiting_for_retry_interval' and retries==1 and read32(controller+4)==3);done()
late({{actor=2}});actor_flags[2]=0x100000;fail_write=2;state={}
ok,reason=patch.apply(api,game,exe,state)
assert(not ok and reason=='query_write_failed' and read32(controller+0x50)==2 and read32(controller+4)==3 and retries==0);done()
late({{actor=2}});actor_flags[2]=0x100000;partial_write=2;state={}
ok,reason=patch.apply(api,game,exe,state)
assert(not ok and reason=='query_write_failed' and read32(controller+0x50)==2 and read32(controller+4)==3 and retries==0);done()
late({{actor=2}});actor_flags[2]=0x100000
local refresh=native.refresh_query
native.refresh_query=function(...)local b,n=refresh(...);avatars[input_offset]=0;return b,n end
run({});assert(writes==0 and retries==0);native.refresh_query=refresh;done()
late({{actor=2}});actor_flags[2]=0x100000
local retry=native.retry;native.retry=function()error('native fixture failure')end
ok,reason=patch.apply(api,game,exe,{})
assert(not ok and reason:find('native_retry_failed',1,true) and read32(controller+4)==3 and read32(controller+0x50)==2)
native.retry=retry;done()

-- A successful new native approach may differ from the retained geometry.
-- Rebuild its private queries rather than discarding an otherwise valid climb.
late({{actor=2}});actor_flags[2]=0x100000
local fresh_controller=ffi.new('uint8_t[0x2b0]');ffi.copy(fresh_controller,control,0x2b0)
u(fresh_controller,4,1)
vector(fresh_controller,488,0,.4,1.9);vector(fresh_controller,500,0,1,1.9)
f(fresh_controller,512,1.3);f(fresh_controller,516,.5);vector(fresh_controller,520,0,1,0)
local fresh_bytes=ffi.string(fresh_controller,0x2b0)
native.context_matches=function(bytes)
    if bytes==fresh_bytes then return true end
    return false,'native_approach_geometry_changed',fresh_bytes
end
native.query_basis=function(direction)
    assert(direction[2]==1)
    return ffi.string(ffi.new('float[16]',{1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}),64)
end
native.refresh_query=function(record,world)
    local position=ffi.new('float[3]');ffi.copy(position,record:sub(65,76),12)
    assert(math.abs(position[1]-.43)<.000001,'Query did not use the new native approach')
    local b,n=refresh(record,world);local out=ffi.new('uint8_t[44]');ffi.copy(out,b,44)
    vector(out,0,0,.43,1)
    return ffi.string(out,44),n
end
state={};local original_queries=api.read(scheduler,1280);local original_controller=api.read(controller,0x2b0)
assert(run(state)=='native_local_vault_started' and retries==1,'Changed native geometry discarded a valid metadata retry')
assert(state.context_reprojections==1 and state.metadata_fallbacks==1
    and state.reprojected_retries==1 and state.reprojected_starts==1)
assert(api.read(scheduler,1280)==original_queries and api.read(controller,0x2b0)==original_controller)
assert(refreshes==1,'Reprojection filled originally empty result slots');done()
local changed_context=native.context_matches
late({{actor=2}});actor_flags[2]=0x100000;refresh_miss=true
run({});assert(refreshes==1 and retries==0 and writes==0);done()
late({{actor=2,normal=.314}});actor_flags[2]=0x100000
run({});assert(refreshes==1 and retries==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000
local exit_validator=native.exit;native.exit=function()return 5 end
run({});assert(refreshes==1 and retries==0 and writes==0);native.exit=exit_validator;done()
late({{actor=2}});actor_flags[2]=0x100000
native.context_matches=function(bytes)
    if bytes==fresh_bytes then return false,'native_approach_blocked' end
    return changed_context(bytes)
end
assert(run({})=='native_context_changed_before_commit' and refreshes==1 and retries==0 and writes==0);done()
for _,edit in ipairs({
    function(b)u(b,684,111)end, -- another avatar
    function(b)u(b,4,0)end, -- failed native approach
    function(b)f(b,512,0)end,
    function(b)f(b,516,3)end,
    function(b)f(b,524,0/0)end,
    function(b)f(b,528,1)end,
}) do
    late({{actor=2}});actor_flags[2]=0x100000
    local bad=ffi.new('uint8_t[0x2b0]');ffi.copy(bad,fresh_bytes,0x2b0);edit(bad)
    native.context_matches=function()return false,'native_approach_geometry_changed',ffi.string(bad,0x2b0)end
    assert(run({})=='unsupported_fresh_approach' and refreshes==0 and retries==0 and writes==0);done()
end
native.context_matches=changed_context
late({{actor=2}});actor_flags[2]=0x100000
local fresh_query=native.refresh_query
native.refresh_query=function(...)local b,n=fresh_query(...);avatars[input_offset]=0;return b,n end
run({});assert(retries==0 and writes==0);done()
native.refresh_query=refresh
late({{actor=2}});actor_flags[2]=0x100000
local basis=native.query_basis;native.query_basis=function()return string.rep('\0',64)end
assert(run({})=='unsupported_query_basis' and refreshes==0 and retries==0 and writes==0)
native.query_basis=basis;done()
native.context_matches=context_matches;native.refresh_query=refresh;native.query_basis=nil

-- A8A710 leaves the automatic-step report (+533) set when the next lower
-- selector finds no candidate. A88160 does not treat that report as a veto.
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1
state={};local step_controller=api.read(controller,0x2b0)
assert(run(state)=='native_local_vault_started' and retries==1,'Retained automatic-step report blocked manual recovery')
assert(api.read(controller,0x2b0)==step_controller and control[533]==1)
assert(state.step_report_retries==1 and state.step_report_starts==1);done()
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1;refresh_miss=true
run({});assert(refreshes==1 and retries==0 and writes==0 and control[533]==1);done()
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1
native.exit=function()return 5 end
run({});assert(retries==0 and writes==0 and control[533]==1);native.exit=exit_validator;done()
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1;control[532]=1
run({});assert(refreshes==0 and retries==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1;u(avatars,flags_offset+12,0x200)
run({});assert(refreshes==0 and retries==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1;u(avatars,flags_offset,0)
run({});assert(refreshes==0 and retries==0 and writes==0);done()
late({{actor=2}});actor_flags[2]=0x100000;control[533]=1
native.context_matches=changed_context;native.query_basis=basis
state={};assert(run(state)=='native_local_vault_started' and state.reprojected_starts==1 and state.step_report_starts==1)
assert(control[533]==1);native.context_matches=context_matches;native.query_basis=nil;done()

-- Assistance discovery uses fresh queries, preserving the ordinary path and
-- refusing to change movement merely on manual input or a retained steep hit.
local candidate_owner={entity=owner+0xf32f18+24}
-- A consumed scheduler slot may be reused while the controller keeps its IDs.
-- Private discovery must rebuild from a fresh native approach, including
-- previously empty hits. Never pass foreign scheduler counts to the driver.
local function reused()
    late({{normal=.5}})
    ffi.fill(queries,1280)
    p(queries,0,manager+0x53e1b8+0x30)
    u(queries,0x68,0x393d9518)
    put(queries,0x74,'uint16_t',64);put(queries,0x76,'uint16_t',64)
end
native.context_matches=function()return true,nil,fresh_bytes end
native.query_basis=basis
local function rebuilt_query(record,world)
    local address=assert(api.pointer(record))
    local slot=(address-controller-0x30)/44
    local b=ffi.new('uint8_t[128]');ffi.copy(b,record,128)
    assert(tonumber(ffi.cast('uint32_t *',b+0x68)[0])==0x05a5271a)
    assert(tonumber(ffi.cast('uint32_t *',b+0x70)[0])==444)
    assert(tonumber(ffi.cast('uint16_t *',b+0x74)[0])==1)
    assert(b[0x7a]==2 and b[0x7b]==1 and b[0x7c]==5)
    assert(record:sub(9,16)==string.rep('\0',8) and record:sub(109,112)==string.rep('\0',4))
    refresh(record,world)
    local out=ffi.new('uint8_t[44]')
    if slot==7 then
        vector(out,0,0,.7,1);vector(out,12,0,0,.5);u(out,28,555);u(out,32,1)
    end
    return ffi.string(out,44),slot==7 and 1 or 0
end
native.refresh_query=rebuilt_query
reused()
local foreign_before=api.read(scheduler,1280)
local local_before=api.read(controller,0x2b0)
local rebuilt_state={}
local rebuilt_kind,rebuilt_reason=patch.assist_candidate(api,game,exe,rebuilt_state,candidate_owner)
assert(rebuilt_kind=='slope' and rebuilt_reason=='validated_steep_candidate',
    'Reused scheduler slots prevented fresh obstacle discovery: '..tostring(rebuilt_reason))
assert(refreshes==10 and rebuilt_state.query_rebuilds==1 and rebuilt_state.context_reprojections==1)
assert(rebuilt_state.candidate_trace.passes.slope[8].unit==555)
assert(writes==0 and retries==0 and api.read(scheduler,1280)==foreign_before
    and api.read(controller,0x2b0)==local_before,'Private discovery changed shared or controller data');done()
-- The direct native consumer still uses shared descriptor counts; do not retry
-- it with reused records, even when discovery can independently find a slope.
reused();assert(run({})=='retained_query_reused' and writes==0 and refreshes==0 and retries==0);done()
local private_snapshot=assert(patch.snapshot(api,game,exe,nil,true))
local retry_ok,retry_reason=patch.retry_consumed(api,private_snapshot,{})
assert(retry_ok and retry_reason=='retained_query_reused' and writes==0 and refreshes==0 and retries==0);done()
-- Unrelated scheduler reuse during private casts must not invalidate local
-- discovery or add foreign records to the local epoch.
reused();native.refresh_query=function(...)
    local b,n=rebuilt_query(...);u(queries,0x68,123);return b,n
end
assert(patch.assist_candidate(api,game,exe,{},candidate_owner)=='slope' and writes==0);done()
-- Input and avatar ownership remain mandatory throughout private discovery.
for _,change in ipairs({function()avatars[input_offset]=0 end,function()u(control,684,999)end}) do
    reused();native.refresh_query=function(...)local b,n=rebuilt_query(...);change();return b,n end
    local _,why=patch.assist_candidate(api,game,exe,{},candidate_owner)
    assert(why=='candidate_changed' and writes==0 and retries==0);done()
end
native.refresh_query=rebuilt_query
for _,context in ipairs({
    function()return true end,
    function()return false,'native_approach_blocked' end,
    function()return false,'unsupported_context',fresh_bytes end,
}) do
    reused();native.context_matches=context
    local _,why=patch.assist_candidate(api,game,exe,{},candidate_owner)
    assert(why=='fresh_approach_unavailable' and refreshes==0 and writes==0 and retries==0,
        'Uninitialized private geometry reached obstacle casting');done()
end
for _,edit in ipairs({
    function(b)u(b,684,111)end,function(b)u(b,4,0)end,
    function(b)f(b,512,0)end,function(b)f(b,516,3)end,function(b)f(b,524,0/0)end,
}) do
    reused();local bad=ffi.new('uint8_t[0x2b0]');ffi.copy(bad,fresh_bytes,0x2b0);edit(bad)
    native.context_matches=function()return true,nil,ffi.string(bad,0x2b0)end
    local _,why=patch.assist_candidate(api,game,exe,{},candidate_owner)
    assert(why=='unsupported_fresh_approach' and refreshes==0 and writes==0 and retries==0);done()
end
-- Recheck returns matched against the new geometry before any allowance.
native.context_matches=changed_context
reused();assert(patch.assist_candidate(api,game,exe,{},candidate_owner)=='slope');done()
native.context_matches=function(bytes)
    if bytes==fresh_bytes then return false,'native_approach_blocked' end
    return changed_context(bytes)
end
reused();local _,changed_reason=patch.assist_candidate(api,game,exe,{},candidate_owner)
assert(changed_reason=='native_context_changed_before_commit' and writes==0 and retries==0);done()
native.context_matches=function()return true,nil,fresh_bytes end
reused();native.refresh_query=function(record,world)refresh(record,world);return string.rep('\0',44),0 end
local _,miss_reason=patch.assist_candidate(api,game,exe,{},candidate_owner)
assert(miss_reason=='no_usable_assisted_candidate' and refreshes==20 and writes==0 and retries==0);done()
native.refresh_query=rebuilt_query
reused();native.exit=function()return 5 end
local _,blocked_reason=patch.assist_candidate(api,game,exe,{},candidate_owner)
assert(blocked_reason=='no_usable_assisted_candidate' and writes==0 and retries==0);native.exit=exit_validator;done()
native.context_matches=context_matches;native.query_basis=nil;native.refresh_query=refresh
-- Without a fresh approach, skip this observation and recover on a valid batch.
late({{normal=.5}})
p(queries,0,manager+0x53e1b8+0x30)
local resumed_state={}
local survived,kind,why=pcall(patch.assist_candidate,api,game,exe,resumed_state,candidate_owner)
assert(survived and kind==nil and why=='fresh_approach_unavailable','Expired candidate query stopped discovery')
assert(writes==0 and refreshes==0 and retries==0)
p(queries,0,controller+0x30)
assert(patch.assist_candidate(api,game,exe,resumed_state,candidate_owner)=='slope','Discovery did not recover')
assert(resumed_state.candidate_results.fresh_approach_unavailable==1 and resumed_state.candidate_results.validated_steep_candidate==1)
done()
late({{normal=.5}});unreadable=pm+0xe8
local unavailable_state={}
local unavailable,unavailable_reason=patch.assist_candidate(api,game,exe,unavailable_state,candidate_owner)
assert(unavailable==nil and unavailable_reason=='candidate_snapshot_unavailable' and unavailable_state.candidate_error)
assert(writes==0 and refreshes==0)
unreadable=nil
assert(patch.assist_candidate(api,game,exe,unavailable_state,candidate_owner)=='slope')
done()

-- v8.5 live failure: reused slots plus a blocked ordinary-height approach
-- prevented any higher-top cast. The native raised search must be independent
-- of that low approach, but may only authorize a private ledge candidate.
local higher=ffi.new('uint8_t[0x2b0]');ffi.copy(higher,fresh_bytes,0x2b0)
vector(higher,488,0,.4,2.4);vector(higher,500,0,1,2.4);f(higher,512,2)
local higher_bytes=ffi.string(higher,0x2b0)
local higher_calls,top_height,top_normal,no_hit=0,2.2,.9,false
local function higher_search(bytes,unit,name,direction,reach)
    assert(unit==444 and name==123 and direction[2]==1 and math.abs(reach-.6)<.00001)
    higher_calls=higher_calls+1
    return higher_bytes
end
local function higher_query(record,world)
    rebuilt_query(record,world) -- Also proves native template ownership/filter.
    local out=ffi.new('uint8_t[44]')
    vector(out,0,0,.7,top_height);vector(out,12,0,0,top_normal);u(out,28,555);u(out,32,1)
    return ffi.string(out,44),no_hit and 0 or 1
end
native.query_basis=basis;native.raised_approach=higher_search;native.refresh_query=higher_query
native.context_matches=function()return false,'native_approach_blocked',nil,4 end
reused();local independent_state={}
local foreign=api.read(scheduler,1280);local unchanged=api.read(controller,0x2b0)
local independent_kind,independent_reason=patch.assist_candidate(api,game,exe,independent_state,candidate_owner)
assert(independent_kind=='ledge' and independent_reason=='validated_raised_top',
    'Blocked low approach still prevented independent higher discovery: '..tostring(independent_reason))
assert(higher_calls==2 and refreshes==10 and independent_state.raised_approach_rebuilds==1)
assert(independent_state.last_approach_code==4 and independent_state.raised_trace.context=='fresh_raised_approach')
assert(writes==0 and retries==0 and api.read(scheduler,1280)==foreign and api.read(controller,0x2b0)==unchanged);done()
for _,setup in ipairs({
    function()top_height=2.51 end,
    function()top_normal=.5 end,
    function()no_hit=true end,
    function()actor_speed[1]=2 end,
    function()native.exit=function()return 5 end end,
}) do
    reused();top_height=2.2;top_normal=.9;no_hit=false;native.exit=exit_validator;setup()
    local kind,why=patch.assist_candidate(api,game,exe,{},candidate_owner)
    assert(kind==nil and why=='no_usable_assisted_candidate' and writes==0 and retries==0);done()
end
top_height=2.5;top_normal=.9;no_hit=false;native.exit=exit_validator
reused();assert(patch.assist_candidate(api,game,exe,{},candidate_owner)=='ledge');done()
for _,change in ipairs({function()avatars[input_offset]=0 end,function()u(control,684,999)end}) do
    reused();native.refresh_query=function(...)local b,n=higher_query(...);change();return b,n end
    local kind,why=patch.assist_candidate(api,game,exe,{},candidate_owner)
    assert(kind==nil and why=='candidate_changed' and writes==0 and retries==0);done()
end
native.refresh_query=higher_query
reused();higher_calls=0
native.raised_approach=function(...)
    local b=higher_search(...)
    if higher_calls==2 then
        local moved=ffi.new('uint8_t[0x2b0]');ffi.copy(moved,b,#b);f(moved,488,.05)
        return ffi.string(moved,0x2b0)
    end
    return b
end
local _,why_moved=patch.assist_candidate(api,game,exe,{},candidate_owner)
assert(why_moved=='raised_context_changed_before_commit' and writes==0);done()
reused();native.raised_approach=function()return nil,'raised_approach_no_ledge'end
local _,why_missing=patch.assist_candidate(api,game,exe,{},candidate_owner)
assert(why_missing=='raised_approach_no_ledge' and refreshes==0 and writes==0);done()
native.raised_approach=higher_search
reused();higher_calls=0;move[15]=1
assert(patch.assist_candidate(api,game,exe,{},candidate_owner)==nil and higher_calls==0);done()
reused();higher_calls=0
assert(run({})=='retained_query_reused' and higher_calls==0 and writes==0 and retries==0);done()
native.raised_approach=nil;native.query_basis=nil;native.context_matches=context_matches;native.refresh_query=refresh

local function candidate(expected)
    local before=api.read(controller,0x2b0)
    local candidate_state={}
    local kind=patch.assist_candidate(api,game,exe,candidate_state,candidate_owner)
    assert(kind==expected,tostring(kind)..' ~= '..tostring(expected))
    assert(writes==0 and retries==0 and api.read(controller,0x2b0)==before,'Candidate probe mutated game data')
    done()
    return candidate_state
end
late({{normal=.9}});candidate(nil)
late({{normal=.5}});candidate('slope')
late({{normal=.314}});candidate(nil)
late({{normal=.5}});refresh_miss=true;candidate(nil)
late({{normal=.5}});actor_speed[1]=2;candidate(nil)
late({{normal=.5}});local saved_exit=native.exit;native.exit=function()return 5 end;candidate(nil);native.exit=saved_exit
late({{normal=.5}});native.context_matches=function()return false end
candidate(nil);assert(refreshes==10);native.context_matches=context_matches
late({{normal=.5}});candidate_owner.entity=candidate_owner.entity+24;candidate(nil);candidate_owner.entity=candidate_owner.entity-24
late({{normal=.314}})
local top_height,top_normal,raised_calls=2.2,.7852,0
native.refresh_query=function(record,world)
    local z=ffi.new('float[1]');ffi.copy(z,record:sub(73,76),4)
    if tonumber(z[0])<.29 then return refresh(record,world) end
    raised_calls=raised_calls+1
    assert(math.abs(tonumber(z[0])-2.84)<.000001,'Probe did not cover the mover-relative height plus box clearance')
    local original=api.read(scheduler+(assert(api.pointer(record))-controller-0x30)/44*128,128)
    assert(record:sub(1,72)==original:sub(1,72) and record:sub(77)==original:sub(77),'Raised cast changed other fields')
    local out=ffi.new('uint8_t[44]');ffi.copy(out,api.read(assert(api.pointer(record)),44),44)
    vector(out,0,0,0,top_height);vector(out,12,0,0,top_normal);u(out,28,555);u(out,32,1)
    return ffi.string(out,44),1
end
candidate('ledge');assert(raised_calls==10)
-- The raised pass keeps its results local: nothing lands in the shared globals.
assert(rawget(_G,'_')==nil,'the ledge candidate search wrote the global _')
late({{normal=.314}});top_height=2.5;candidate('ledge')
late({{normal=.314}});top_height=.1
assert(candidate(nil).raised_trace.passes.raised[1].result=='below_ledge_minimum')
late({{normal=.314}});top_height=2.51
local height_trace=candidate(nil).candidate_trace
assert(height_trace.result=='no_usable_assisted_candidate' and #height_trace.passes.raised==10)
assert(height_trace.passes.raised[1].result=='height' and height_trace.passes.raised[1].height>2.5)
assert(math.abs(height_trace.passes.raised[1].source_height-2.84)<.000001)
late({{normal=.314}});top_height=2.2;top_normal=.45
assert(candidate(nil).candidate_trace.passes.raised[1].result=='surface_angle')
late({{normal=.314}});top_normal=.7852;native.exit=function()return 5 end
local exit_trace=candidate(nil).candidate_trace.passes.raised[1]
assert(exit_trace.result=='native_exit' and exit_trace.exit==5);native.exit=saved_exit
late({{normal=.314}});move[15]=1;raised_calls=0;candidate(nil);assert(raised_calls==0)
late({});candidate('ledge') -- A previously empty slot can reveal a top higher up.
late({{normal=.314}});local probe=native.refresh_query
native.refresh_query=function(...)local b,n=probe(...);avatars[input_offset]=0;return b,n end
candidate(nil)
native.refresh_query=refresh

-- The live search ceiling was about 1.93 above the native mover. A fixed
-- +0.41 lift still contacts the face below the nearby 2.45-2.50 top.
-- Model that initial-overlap refusal: the full query box must start clear.
late({{normal=.314}})
for slot=0,9 do f(queries+slot*128,72,1.928206) end
native.refresh_query=function(record,world)
    local z=ffi.new('float[1]');ffi.copy(z,record:sub(73,76),4)
    if tonumber(z[0])<2.75 then return refresh(record,world) end
    local out=ffi.new('uint8_t[44]')
    vector(out,0,0,0,2.48);vector(out,12,0,0,.7852);u(out,28,555);u(out,32,1)
    return ffi.string(out,44),1
end
candidate('ledge')
late({{normal=.314}})
for slot=0,9 do f(queries+slot*128,72,.52) end
assert(math.abs(candidate('ledge').raised_trace.passes.raised[1].source_height-2.84)<.000001)
late({{normal=.314}})
local mover_position=native.mover_position
native.mover_position=function()return {0,0,.125} end
local translated=candidate('ledge').raised_trace
assert(translated.root[3]==.125 and math.abs(translated.passes.raised[1].source_height-2.84)<.000001)
assert(math.abs(translated.passes.raised[1].height-2.355)<.000001)
native.mover_position=mover_position
for _,context_reason in ipairs({'native_approach_blocked','native_approach_geometry_changed'}) do
    late({{normal=.314}})
    native.context_matches=function()return false,context_reason end
    local observed=candidate('ledge')
    assert(observed.raised_context_fallbacks==1 and observed.raised_trace.context==context_reason)
    assert(#observed.raised_trace.passes.ordinary==0 and #observed.raised_trace.passes.slope==0)
end
late({{normal=.314}});f(queries,64,20)
candidate(nil);assert(refreshes==0)
late({{normal=.314}});native.exit=function()return 5 end
assert(candidate(nil).raised_trace.passes.raised[1].result=='native_exit');native.exit=saved_exit
late({{normal=.314}});native.context_matches=function()return false,'unsupported_context' end
candidate(nil);assert(refreshes==0)
-- Private discovery's relaxed context never reaches controller consumption.
late({{normal=.9}});native.context_matches=function()return false,'native_approach_blocked' end
f(settings,0x104,2.5)
assert(run({})=='native_approach_blocked' and writes==0 and retries==0 and refreshes==0)
f(settings,0x104,1.95);native.context_matches=context_matches;done()
native.refresh_query=refresh

-- A later ordinary success must not erase the last raised-search rejection.
local diagnostic_state={}
late({{normal=.314}})
assert(patch.assist_candidate(api,game,exe,diagnostic_state,candidate_owner)==nil)
local last_raised=diagnostic_state.raised_trace
assert(last_raised and #last_raised.passes.raised==10)
late({{normal=.9}})
assert(patch.assist_candidate(api,game,exe,diagnostic_state,candidate_owner)==nil)
assert(diagnostic_state.raised_trace==last_raised and diagnostic_state.candidate_trace~=last_raised)
assert(diagnostic_state.candidate_trace.result=='ordinary_candidate_retained');done()

late({{normal=.5}});actor_speed[1]=2
assert(candidate(nil).candidate_trace.passes.slope[1].result=='actor_motion')
late({{normal=.5}});refresh_miss=true
assert(candidate(nil).candidate_trace.passes.slope[1].result=='no_hit')
late({{normal=.5}});state={}
assert(patch.assist_candidate(api,game,exe,state,candidate_owner)=='slope')
local retained_trace=state.candidate_trace
avatars[input_offset]=0
assert(patch.assist_candidate(api,game,exe,state,candidate_owner)==nil and state.candidate_trace==retained_trace)
assert(state.candidate_results.waiting_for_manual_vault==1 and retained_trace.result=='validated_steep_candidate');done()
late({{normal=.5}});actor_speed[1]=0/0
local valid_call=pcall(patch.assist_candidate,api,game,exe,{},candidate_owner)
assert(not valid_call and writes==0,'Invalid native result must still reach loader cleanup');done()

-- The identity chain from the slope check of the same poll stands in for the
-- vault's own reads: the same guards in the same order (addresses, bytes and
-- epoch) and the same plan as a snapshot that reads the chain itself.
do
    reset({{actor=2},{}});actor_flags[2]=0x100000
    local full=assert(patch.snapshot(api,game,exe,nil,nil,nil))
    local in_epoch,chain={},{}
    for _,g in ipairs(full.epoch) do in_epoch[g]=true end
    for i=1,17 do local g=full.guards[i];chain[i]={address=g.address,bytes=g.bytes,epoch=in_epoch[g]} end
    local avatar={identity=chain,key={owner=owner,manager=manager,id=222},entity=owner+0xf32f18+24,
        entity_bytes=ffi.string(entities+24,24),ai=1}
    local reused=assert(patch.snapshot(api,game,exe,nil,nil,nil,avatar))
    assert(#reused.guards==#full.guards and #reused.epoch==#full.epoch and reused.entity==full.entity)
    for i,g in ipairs(full.guards) do
        assert(reused.guards[i].address==g.address and reused.guards[i].bytes==g.bytes)
    end
    for i,g in ipairs(full.epoch) do assert(reused.epoch[i].address==g.address and reused.epoch[i].bytes==g.bytes) end
    local planned,reused_plan=patch.plan(full),patch.plan(reused)
    assert(#planned>0 and #planned==#reused_plan)
    for i,w in ipairs(planned) do
        assert(reused_plan[i].address==w.address and reused_plan[i].before==w.before and reused_plan[i].after==w.after)
    end
    done()
end
-- Per-check call budget of patch.apply without slope assistance (the full
-- check is budgeted in test_slope.lua; the loader runs one check per frame, two
-- while something is in progress).
-- Fixture writes query protection first, as the Windows adapter's write and
-- write_batch do.
do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local counts=budget.wrap(api)
    local function check(label,s,limits,expected)
        local frame,ok,reason=budget.frame(counts,patch.apply,api,game,exe,s)
        assert(ok and reason==expected,label..': '..tostring(reason))
        budget.check(frame,limits,label)
    end
    -- read_into: the same ReadProcessMemory as read (about 1-2 us in game),
    -- into a reused buffer. Every snapshot's mission gate reads the mode pointer
    -- and record that way and decodes them in place (one api.pointer less), so
    -- a check outside a mission allocates nothing; the read count is unchanged.
    reset({});u(mission,8,0)
    check('outside a mission',{},{read_into=2},'waiting_for_mission');u(mission,8,1)
    reset({});u(control,4,0)
    check('idle, no vault query',{},{read=17,read_into=2,pointer=7},'waiting_for_vault_query')
    reset({{actor=2},{}});avatars[input_offset]=0
    check('native query, input released',{},{read=20,read_into=2,pointer=7},'waiting_for_manual_vault')
    reset({{actor=2},{}});actor_flags[2]=0x100000;local s={}
    -- A commit or restore is one write_batch: one protection query for the
    -- local controller. Its writes reach it as offsets (api.distance, one per
    -- write: arithmetic, no system call).
    check('vault alternative prepared',s,{read=176,read_into=2,pointer=24,distance=11,native=1,writable_data=1,
        write_batch=1},
        'local_manual_alternative_prepared')
    -- A held vault keeps its prepared write while the check would prepare the
    -- same one: no restore, no write and no protection query, and no second
    -- read of the guards the snapshot has just read.
    check('vault held, write kept',s,{read=92,read_into=2,pointer=24,distance=10,native=1},
        'local_manual_alternative_prepared')
    avatars[input_offset]=0
    check('vault released, restored',s,{read=46,read_into=2,pointer=7,distance=1,writable_data=1,write_batch=1},
        'waiting_for_manual_vault')
    assert(not s.pending)
    late({{actor=2},{}});actor_flags[2]=0x100000
    -- One batch before the native retry and one restoring after it.
    check('late native retry',{},{read=234,read_into=2,pointer=27,distance=13,native=1,time=1,writable_data=2,
        write_batch=2},
        'native_local_vault_started')
    -- Slope/ledge candidate validation: at most once per 0.1 s during a press.
    late({{normal=.5}})
    local frame,kind=budget.frame(counts,patch.assist_candidate,api,game,exe,{},candidate_owner)
    assert(kind=='slope');budget.check(frame,{read=125,read_into=2,pointer=26,distance=11,native=1,time=1},'candidate')
end
print('PASS: per-check call budget: no protection queries while idle or waiting for a manual vault')

-- Real Windows adapter (memory from bingus_memory.lua and bingus_write.lua, as the build hands it
-- over) only writes existing private PAGE_READWRITE data.
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local memory=assert(loadfile(source..'/bingus_write.lua'))().extend(assert(loadfile(source..'/bingus_memory.lua'))().new(runtime))
local real=assert(loadfile(source..'/windows_api.lua'))()(runtime,memory)
assert(real==memory and type(real.time())=='number','the adapter takes the runtime clock')
local allocation=ffi.new('uint8_t[16]')
assert(real.writable_data(allocation,16) and real.write(allocation,'abcdefgh'))
assert(real.read(allocation,8)=='abcdefgh')
assert(not real.writable_data(real.module(nil),8) and not real.write(real.module(nil),'abcdefgh'))
local batched,landed=real.write_batch(allocation,16,{{0,'12'},{14,'34'}})
assert(batched and landed==2 and real.read(allocation,16)=='12cdefgh\0\0\0\0\0\0' .. '34')
batched,landed=real.write_batch(allocation,16,{{0,'ab'},{15,'xy'}})
assert(not batched and landed==1 and real.read(allocation,2)=='ab','A change past the batch must stop it')
batched,landed=real.write_batch(real.module(nil),8,{{0,'abcdefgh'}})
assert(not batched and landed==0)
done()
print('PASS: '..passed..' local query, native-check model, identity, worker, transition, rollback and Windows permission scenarios')
