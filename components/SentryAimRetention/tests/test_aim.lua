local src=assert(arg[1]);local ffi=require('ffi')
local M=assert(loadfile(src..'/aim_data.lua'))()
local function word(n)return ffi.string(ffi.new('uint32_t[1]',n),4)end
local function number(n)return ffi.string(ffi.new('float[1]',n),4)end
local function vec(x,y,z)return ffi.string(ffi.new('float[3]',x,y,z),12)end
local function uint(b)local v=ffi.new('uint32_t[1]');ffi.copy(v,b,4);return tonumber(v[0])end
local function clone(t)local n={};for k,v in pairs(t)do n[k]=v end;return n end
local function fixture()
    local mem,regions,entities,calls={},{},{},{}
    local api={}
    local function put(a,b)for i=1,#b do mem[a+i-1]=b:sub(i,i)end end
    function api.read(a,n)local t={};for i=0,n-1 do if not mem[a+i]then return nil end;t[#t+1]=mem[a+i]end;return table.concat(t)end
    function api.writable_data(a,n)return not api.deny and api.read(a,n)~=nil end
    function api.write(a,b)
        if not api.writable_data(a,#b)then return false end
        if api.partial==a then api.partial=nil;put(a,b:sub(1,6));return false end
        put(a,b);return true
    end
    function api.pointer(b)local v=ffi.new('uint64_t[1]');ffi.copy(v,b,8);return tonumber(v[0])end
    local native={}
    function native.retention(id,enabled)
        local s=entities[id];local flags=uint(api.read(s.flags_address,4))
        calls[#calls+1]={'flags',id,enabled};local bit=require('bit')
        put(s.flags_address,word(enabled and bit.bor(flags,2) or bit.band(flags,bit.bnot(2))))
        if api.throw_flags then api.throw_flags=nil;error('setter exception')end
    end
    for name,offset in pairs({horizontal=8,vertical=12})do
        native[name]=function(entity,speed)
            local s=entities[entity];calls[#calls+1]={name,entity,speed}
            if api.fail_axis==name then api.fail_axis=nil;return end
            put(s.control_address+offset,number(speed))
        end
    end
    local function sentry(id,base)
        base=base or id*1000
        local s={id=id,key='instance'..id,entity=id,profile='Gatling',guards={{address=base,bytes='identity'}},
            enabled=true,node=12,target=77,runtime_target=77,has=true,source_flags=3,
            point=vec(40,20,0),raw=vec(40,20,2),computed=vec(40,20,2),
            flags=0,horizontal=number(150),vertical=number(90),flags_address=base+32,
            raw_address=base+40,computed_address=base+52,control_address=base+72}
        put(base,'identity');put(s.flags_address,word(0));put(s.raw_address,s.raw);put(s.computed_address,s.computed)
        put(s.control_address,string.rep('\0',16));put(s.control_address+8,s.horizontal);put(s.control_address+12,s.vertical)
        entities[id]=s;return s
    end
    local function fresh(s)
        s=clone(s);s.flags=uint(api.read(s.flags_address,4));s.raw=api.read(s.raw_address,12)
        s.computed=api.read(s.computed_address,12);s.horizontal=api.read(s.control_address+8,4)
        s.vertical=api.read(s.control_address+12,4);entities[s.id]=s;return s
    end
    return api,native,sentry,fresh,put,calls
end
local passed=0
local function test(name,fn)fn();passed=passed+1;print('PASS: '..name)end
test('loss during firing holds aim and both axes; native scan command releases',function()
    local api,native,new,fresh,put=fixture();local state={};local s=new(1)
    assert(M.step(api,native,{s},state));s.target=0;s.source_flags=32
    s.raw=vec(40,20,0);s.computed=s.raw;put(s.raw_address,s.raw);put(s.computed_address,s.raw)
    assert(M.step(api,native,{s},state));s=fresh(s)
    assert(s.flags==2 and s.raw==vec(40,20,2) and s.horizontal==number(0) and s.vertical==number(0))
    assert(state.holds==1 and state.late_aim==1)
    s.point=vec(1,2,3);assert(M.step(api,native,{s},state));assert(state.holding==1) -- firing node
    s.node=3;s.point=vec(0,0,0);assert(M.step(api,native,{s},state));assert(state.holding==1) -- transition placeholder
    s.point=vec(10,30,2);assert(M.step(api,native,{s},state));s=fresh(s)
    assert(state.releases==1 and state.holding==0 and s.flags==0)
    assert(s.horizontal==number(150) and s.vertical==number(90))
end)
test('new target releases immediately without resetting tracking speeds',function()
    local api,native,new,fresh=fixture();local state={};local s=new(1)
    M.step(api,native,{s},state);s.target=0;s.has=false;M.step(api,native,{s},state)
    s=fresh(s);s.target=88;s.has=true;s.source_flags=3
    assert(M.step(api,native,{s},state));assert(fresh(s).flags==0 and state.holding==0)
end)
test('independent sentries and clean shutdown; no acquisition during initial idle',function()
    local api,native,new,fresh=fixture();local state={};local a,b,c=new(1),new(2),new(3)
    c.target=0;c.node=2;c.source_flags=32
    M.step(api,native,{a,b,c},state);a.target=0;a.has=false
    M.step(api,native,{a,b,c},state)
    assert(fresh(a).flags==2 and fresh(b).flags==0 and fresh(c).flags==0)
    assert(M.stop(api,nil,nil,setmetatable(state,{__index={native=native}})))
    assert(fresh(a).flags==0 and fresh(a).horizontal==number(150))
end)
test('existing native disable masks are not taken over or cleared',function()
    for _,flags in ipairs({1,2,3,16})do
        local api,native,new,fresh,put,calls=fixture();local state={};local s=new(1)
        M.step(api,native,{s},state);s.target=0;s.flags=flags;put(s.flags_address,word(flags))
        assert(M.step(api,native,{s},state));assert(#calls==0 and fresh(s).flags==flags)
    end
end)
test('partial aim write and setter failure restore only acquired values',function()
    for _,failure in ipairs({'partial','axis','throw'})do
        local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
        M.step(api,native,{s},state);s.target=0;s.raw=vec(3,4,5);s.computed=s.raw
        put(s.raw_address,s.raw);put(s.computed_address,s.raw)
        if failure=='partial'then api.partial=s.raw_address
        elseif failure=='axis'then api.fail_axis='vertical'else api.throw_flags=true end
        local ok,accepted=pcall(M.step,api,native,{s},state)
        assert(not ok or not accepted);assert(M.stop(api,nil,nil,state))
        s=fresh(s);assert(s.flags==0 and s.horizontal==number(150) and s.vertical==number(90))
        assert(s.raw==vec(3,4,5))
    end
end)
test('memory refusal and changed identity prevent writes',function()
    local api,native,new,fresh,put,calls=fixture();local state={native=native};local s=new(1)
    M.step(api,native,{s},state);s.target=0;api.deny=true
    assert(not M.step(api,native,{s},state));assert(#calls==0)
    api.deny=false;put(s.guards[1].address,'replaced')
    assert(M.step(api,native,{s},state));assert(#calls==0)
end)
test('one failed rollback does not prevent the remaining controls from releasing',function()
    local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
    M.step(api,native,{s},state);s.target=0;s.raw=vec(3,4,5);s.computed=s.raw
    put(s.raw_address,s.raw);put(s.computed_address,s.raw);api.partial=s.raw_address
    assert(not M.step(api,native,{s},state))
    local write=api.write;api.write=function(a,b)if a==s.raw_address then return false end;return write(a,b)end
    assert(not M.stop(api,nil,nil,state));local current=fresh(s)
    assert(current.flags==0 and current.horizontal==number(150) and current.vertical==number(90))
    api.write=write;assert(M.stop(api,nil,nil,state))
end)
test('rollback writes skip the query only inside the aim range the release just checked',function()
    for _,moved in ipairs({false,true})do
        local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
        M.step(api,native,{s},state);s.target=0;s.raw=vec(3,4,5);s.computed=s.raw
        put(s.raw_address,s.raw);put(s.computed_address,s.raw);api.partial=s.computed_address
        assert(not M.step(api,native,{s},state))
        local lease=state.records[1].lease
        if moved then -- the release checks another aim range than the one written
            local copy=clone(lease.snapshot);copy.raw_address=s.raw_address+0x400
            put(copy.raw_address,string.rep('\0',24));lease.snapshot=copy
        end
        local checks={};local write=api.write
        api.write=function(a,b,checked)checks[#checks+1]=checked==true;return write(a,b)end
        assert(M.release(api,native,lease))
        assert(#checks==2 and checks[1]==not moved and checks[2]==not moved)
        assert(api.read(s.raw_address,12)==vec(3,4,5) and api.read(s.computed_address,12)==vec(3,4,5))
    end
end)
test('compaction follows the same entity and preserves customized restore values',function()
    local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
    M.step(api,native,{s},state);s.target=0;M.step(api,native,{s},state);s=fresh(s)
    local relocated=new(1,90000);relocated.target=0;relocated.source_flags=32;relocated.node=12
    put(relocated.flags_address,word(2));put(relocated.control_address+8,number(0));put(relocated.control_address+12,number(0))
    put(s.guards[1].address,'retired!');relocated=fresh(relocated)
    assert(M.step(api,native,{relocated},state));assert(state.holding==1)
    assert(M.stop(api,nil,nil,state));relocated=fresh(relocated)
    assert(relocated.flags==0 and relocated.horizontal==number(150) and relocated.vertical==number(90))
end)

test('map replacement without moving component slots cannot orphan an aim hold',function()
    for _,release in ipairs({'target','scan','shutdown'})do
        local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
        put(90000,'old map!');s.guards[2]={address=90000,bytes='old map!'}
        M.step(api,native,{s},state);s.target=0;s.has=false;M.step(api,native,{s},state)
        s=fresh(s)
        -- Native hash-table allocation changed, but all component data addresses
        -- and the sentry instance remained the same.
        put(90000,'new map!');s.guards={s.guards[1],{address=90000,bytes='new map!'}}
        if release=='target' then s.target=88;s.has=true;s.source_flags=3
        elseif release=='scan' then s.has=true;s.node=2;s.source_flags=32;s.point=vec(1,3,2) end
        assert(M.step(api,native,{s},state))
        if release=='shutdown' then assert(M.stop(api,nil,nil,state))end
        s=fresh(s)
        assert(s.flags==0 and s.horizontal==number(150) and s.vertical==number(90))
    end
end)
test('native speed changes are preserved when control is reclaimed',function()
    local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
    M.step(api,native,{s},state);s.target=0;M.step(api,native,{s},state)
    put(s.control_address+8,number(42));s=fresh(s)
    assert(M.step(api,native,{s},state));s=fresh(s)
    assert(s.flags==0 and s.horizontal==number(42) and s.vertical==number(90))
end)
test('native adds another disable bit or unrelated entity flag during a hold',function()
    local api,native,new,fresh,put=fixture();local state={native=native};local s=new(1)
    s.authority_address=90000;put(s.authority_address,'\1')
    M.step(api,native,{s},state);s.target=0;M.step(api,native,{s},state)
    put(s.flags_address,word(18));put(s.authority_address,'\5');s=fresh(s)
    assert(M.step(api,native,{s},state));s=fresh(s)
    assert(s.flags==16 and s.horizontal==number(150) and s.vertical==number(90))
end)
test('native clears retention, despawn, and repeated cycles leave no stale writes',function()
    local api,native,new,fresh,put,calls=fixture();local state={native=native};local s=new(1)
    M.step(api,native,{s},state);s.target=0;M.step(api,native,{s},state)
    put(s.flags_address,word(0));s=fresh(s);M.step(api,native,{s},state)
    assert(fresh(s).horizontal==number(150));assert(M.stop(api,nil,nil,state))
    s=new(2);M.step(api,native,{s},state);s.target=0;M.step(api,native,{s},state)
    put(s.guards[1].address,'removed!');local before=#calls
    assert(M.step(api,native,{},state));assert(#calls==before and not next(state.records))
end)

-- The actual captured target-loss sequence is converted to compact Lua rows.
-- Replay tests decisions, not native callback scheduling or projectile physics.
if arg[2]then
test('recorded Gatling losses retain aim through fallback and allow reacquisition/scanning',function()
    local frames=assert(loadfile(arg[2]))();local api,native,new,fresh,put=fixture()
    local state={native=native};local s=new(1);local held=0;local replayed=0
    for _,row in ipairs(frames)do
        s=fresh(s);s.node=row.node;s.target=row.target;s.runtime_target=row.runtime_target
        s.has=row.has;s.source_flags=row.flags;s.point=vec(unpack(row.point))
        -- Native targeting cannot replace the aim while our bit is set.
        if s.flags==0 then
            s.raw=vec(unpack(row.raw));s.computed=vec(unpack(row.computed))
            put(s.raw_address,s.raw);put(s.computed_address,s.computed)
        end
        assert(M.step(api,native,{s},state));replayed=replayed+1
        if state.holding>0 then held=held+1;assert(fresh(s).horizontal==number(0))end
    end
    assert(replayed>100 and held>20 and state.holds>=8 and state.releases>=8)
    assert(state.holding==0);assert(M.stop(api,nil,nil,state))
    print(string.format('Replay: %d samples, %d held, %d holds, %d releases',replayed,held,state.holds,state.releases))
end)
end
print('PASS: '..passed..' aim-retention regression cases')
