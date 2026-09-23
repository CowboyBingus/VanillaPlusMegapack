-- Synthetic supported image and weapon tables; all Windows calls are stubs.
local source=assert(arg[1])
local ffi=require('ffi')
local GAME, REGION, SIZE = 0x100000, 0x10000000, 0x120000
local TRIGGER, CHARGE, ENTITIES, FLAGS, CHARGED, ENTRIES = 0x20000,0x30000,0x40000,0x50000,0x60000,0x70000
local WEAPON, SECOND = 0x80000,0x81000
local fingerprint='\x0f\xd7\xd6\x1a\x96\xfb\xa2\x29\xa9\x31\xee\x67\x0e\x04\x95\x41'
local resource='\xe6\x06\x73\x0f\xd5\x9c\xde\x96'
local signature='\x48\x89\x4c\x24\x08\x53\x55\x56\x57\x41\x57\x48\x83\xec\x20'
local region=ffi.new('uint8_t[?]',SIZE)
-- The fingerprint straddles the first 64 KiB boundary.
local record=65536-8-168
local function putf(buffer,offset,value)
    local v=ffi.new('float[1]',value);ffi.copy(buffer+offset,v,4)
end
putf(region,record,1);putf(region,record+24,1.1);putf(region,record+48,1.2)
putf(region,record+72,0.7);putf(region,record+76,1.4)
ffi.copy(region+record+168,fingerprint,#fingerprint)
local function integer(value,kind)
    local x=ffi.new((kind or 'uint64_t')..'[1]',value)
    return ffi.string(x,ffi.sizeof(x))
end
local function blob(size,values)
    local b=ffi.new('uint8_t[?]',size)
    for offset,bytes in pairs(values) do ffi.copy(b+offset,bytes,#bytes) end
    return ffi.string(b,size)
end
local clock,down,weapon,second,charge=0,false,'ordinary',false,0.5
local reads,queries,bytes,charge_reads,writes,patches,logs,updates,renders=0,0,0,0,0,0,0,0,0
local mode=arg[2] or 'normal'
local max_read, cost = 0, mode=='normal' and 0 or 1200
local local_bytes={}
local function put(a,b)for i=1,#b do local_bytes[a+i-1]=b:sub(i,i)end end
local function u(v)return integer(v,'uint32_t')end
local PM,OWNER,AM,AVATAR=0x20000000,0x21000000,0x23000000,0x21f32f30
local input=AM+0x150+0xa7aec+0x1b68+9*32 -- local avatar is index one
for rva,a in pairs({[0x3326468]=PM,[0x346bf98]=OWNER,[0x3326d20]=AM})do put(GAME+rva,integer(a))end
put(PM+0x84,u(2)..u(2));put(PM+0x3a8,u(9));put(PM+0xe8,integer(0x24000000))
put(0x24000000,blob(24,{[20]='\1'}))
local avatar=blob(24,{[0]='\x97\xfa\x4d\x29\x4d\x33\x1c\x4d',[8]=u(222),[12]=u(4194313),[20]='\1'})
put(AVATAR,avatar);put(AM+0x6c,u(2));put(AM+0x118,integer(AVATAR))
local function map(header,rows,key,index)
    put(header,integer(rows)..u(8)..u(0xffffffff)..u(1))
    put(rows,string.rep('\255',64));put(rows+key%8*8,u(key)..u(index))
end
map(OWNER+0xf22ec8,0x25000000,9,1);map(AM+0xf8,0x25000100,222,1)
put(GAME+0x3326dc0,integer(0x26000000));map(0x26000000+32,0x25000200,77,1)
put(0x26000000+64,integer(0x26000100));put(0x26000100+48+4,u(222))
local relocated, generation, input_valid, command=false,1,true,true
local scenario=arg[3]
local blocked,trigger_count,trigger_slot={},2,0
local trigger_dense=false
local held_time,full_time=.5,1.2
local record2=200000
local function install_record(at)
    ffi.copy(region+at,region+record,216);region[at+184]=0
end
local function slot()return second and 510 or (relocated and 3 or 511)end
local function entry_base()return ENTRIES+(relocated and 0x10000 or 0)end
local function memory(address,size)
    if blocked[address] then return nil end
    if address==input then return input_valid and blob(32,{[8]=integer(down and held_time or 0,'float')}) or nil end
    if local_bytes[address] then
        local b={};for i=0,size-1 do if not local_bytes[address+i] then return nil end;b[#b+1]=local_bytes[address+i]end
        return table.concat(b)
    end
    if address>=REGION and address+size<=REGION+SIZE then
        return ffi.string(region+address-REGION,size)
    end
    if address==GAME+0x755f90 then return signature end
    if address==GAME+0x3326660 then return integer(TRIGGER) end
    if address==GAME+0x3326c20 then charge_reads=charge_reads+1;return integer(CHARGE) end
    if address==TRIGGER+24 then
        return blob(72,{[0]=integer(trigger_count,'uint32_t'),[40]=integer(ENTITIES),[64]=integer(FLAGS)})
    end
    if address>=FLAGS and address+size<=FLAGS+trigger_count then
        local flags=trigger_dense and string.rep('\1',trigger_count)
            or blob(trigger_count,{[(second and 1 or trigger_slot)]=command and '\1' or '\0'})
        return flags:sub(address-FLAGS+1,address-FLAGS+size)
    end
    if address>=ENTITIES and address+size<=ENTITIES+trigger_count*8 then
        local entities
        if trigger_dense then
            entities=string.rep(integer(0x90000),trigger_slot)..integer(WEAPON)
                ..string.rep(integer(0x90000),trigger_count-trigger_slot-1)
        else
            entities=blob(trigger_count*8,{[trigger_slot*8]=integer(WEAPON),[8]=integer(SECOND)})
        end
        return entities:sub(address-ENTITIES+1,address-ENTITIES+size)
    end
    if address==0x90000 then return blob(24,{[0]='ordinary'}) end
    if address==WEAPON or address==SECOND then
        return blob(24,{[0]=(weapon=='arc' and resource or 'ordinary'),[8]=u(77),[16]=u(generation),[20]='\1'})
    end
    if address==CHARGE+16 then
        return blob(56,{[0]=integer(512,'uint32_t'),[40]=integer(CHARGED),[48]=integer(entry_base())})
    end
    if address>=CHARGED and address+size<=CHARGED+512*8 then
        local pointers=blob(512*8,{[510*8]=integer(SECOND),[(relocated and 3 or 511)*8]=integer(WEAPON)})
        return pointers:sub(address-CHARGED+1,address-CHARGED+size)
    end
    if address==entry_base()+511*40 or address==entry_base()+510*40 or address==entry_base()+3*40 then
        local b=ffi.new('uint8_t[40]');putf(b,4,charge);putf(b,8,full_time);b[12]=1
        return ffi.string(b,40)
    end
    return nil
end
local kernel={}
function kernel.GetModuleHandleA() return ffi.cast('void *',GAME) end
function kernel.GetCurrentProcess() return ffi.cast('void *',1) end
function kernel.QueryPerformanceFrequency(p) p[0]=1000000;return 1 end
function kernel.QueryPerformanceCounter(p) p[0]=clock;return 1 end
function kernel.GetTickCount64() return math.floor(clock/1000) end
function kernel.ReadProcessMemory(_,address,buffer,size,count)
    address,size=tonumber(ffi.cast('uintptr_t',address)),tonumber(size)
    reads,bytes=reads+1,bytes+size;max_read=math.max(max_read,size);clock=clock+cost
    local data=memory(address,size)
    if mode=='stale' and size>216 and data and data:find(fingerprint,1,true) then
        ffi.fill(region+record+168,#fingerprint,0) -- allocation changed after the scan snapshot
    end
    if not data or #data~=size then return 0 end
    ffi.copy(buffer,data,size);count[0]=size;return 1
end
function kernel.VirtualQueryEx(_,address,info)
    queries=queries+1;clock=clock+cost
    address=tonumber(ffi.cast('uintptr_t',address))
    if address==0 then info.BaseAddress=ffi.cast('void *',0);info.RegionSize=REGION;info.State=0;return 48 end
    if address==REGION then
        info.BaseAddress=ffi.cast('void *',REGION);info.RegionSize=SIZE
        info.State=0x1000;info.Protect=2;info.Type=0x20000;return 48
    end
    return 0
end
function kernel.VirtualProtectEx(_,address,size,protection,previous)
    address=tonumber(ffi.cast('uintptr_t',address))
    assert((address==REGION+record+184 or address==REGION+record2+184) and size==1)
    previous[0]=2;return 1
end
function kernel.WriteProcessMemory(_,address,data,size,written)
    address=tonumber(ffi.cast('uintptr_t',address))
    assert(size==1 and ffi.string(data,1)=='\1')
    if address==REGION+record+184 or address==REGION+record2+184 then
        patches=patches+1;region[address-REGION]=1
    else
        assert(address==entry_base()+slot()*40+12,'wrong weapon entry')
        writes=writes+1
    end
    written[0]=size;return 1
end
local bindings=setmetatable({load=function(name)
    if name=='kernel32' then return kernel end
    error('Raw mouse state must not decide the native Fire action: '..name)
end},{__index=ffi})
local log_text={}
local env=setmetatable({},{__index=_G});env._G=env
env.ArcThrowerDiagnostics=scenario=='diagnostic-recovery'
env.require=function(name) return name=='ffi' and bindings or require(name) end
env.CowboyBingusModLoader={api=1,open_log=function()
    return {write=function(_,text)
        assert(not text:find('error #',1,true),text);logs=logs+1;log_text[#log_text+1]=text
    end,flush=function() end}
end}
env.update=function(_,marker) assert(marker=='original');updates=updates+1;return 1,nil,3 end
env.render=function() renders=renders+1;return 4,nil,6 end
local render=env.render
setfenv(assert(loadfile(source)),env)()
assert(env.render==render,'render must not run a second assist')
local function tick()
    clock=clock+10000
    local old_bytes,old_queries=bytes,queries
    local a,b,c=env.update(.01,'original');assert(a==1 and b==nil and c==3)
    assert(bytes-old_bytes<=262144+16384,'one update exceeded the scan/read budget')
    assert(queries-old_queries<=16,'one update exceeded the region-query budget')
    local old_reads,old_writes=reads,writes
    local x,y,z=env.render();assert(x==4 and y==nil and z==6)
    assert(reads==old_reads and writes==old_writes,'render duplicated native work')
end
for _=1,20 do tick() end
if mode=='stale' then
    assert(patches==0,'a stale fingerprint must never authorize a write')
    print('PASS: stale scan snapshot revalidated before writing')
    return
end
assert(patches==1 and max_read<=65536,'bounded scan must find a split fingerprint and patch exactly once')
if scenario then
    local function ticks(n)for _=1,n do tick()end end
    if scenario=='large-trigger-table' or scenario=='sparse-trigger-table' then
        trigger_count=scenario=='large-trigger-table' and 65 or 4096
        trigger_slot=trigger_count-1;down=true;weapon='arc'
        tick();assert(writes==1,'active Arc at the end of a sparse table must arm on first discovery')
        down=false;tick();local before=writes;trigger_count=0xffffffff;down=true;ticks(30)
        assert(writes==before,'corrupt table size must not authorize writes')
    elseif scenario=='dense-trigger-table' then
        trigger_count=4096;trigger_slot=64;trigger_dense=true;down=true;weapon='arc'
        local before=reads;tick()
        assert(writes==0 and charge_reads==0,'first batch must stop before active candidate 65')
        assert(reads-before<200,'dense trigger discovery must bound native candidate reads')
        ticks(12);assert(writes>0,'next batch must reach the active Arc command')
    else
        weapon='arc';down=true;tick();assert(writes==1)
        charge=.8;tick();charge=0;command=false;tick()
        local before=writes
        if scenario=='patch-reset' then
            region[record+184]=0;ticks(30)
            assert(region[record+184]==1 and patches==2,'lost static auto-fire flag must be repaired')
        elseif scenario=='patch-replaced' then
            install_record(record2);region[record+168]=0;region[record+184]=0;ticks(100)
            assert(region[record2+184]==1,'replacement record must be discovered and patched')
            assert(region[record+184]==0,'invalid old record must never be patched')
        elseif scenario=='patch-shadow-copy' then
            install_record(record2);charge=full_time;ticks(400)
            assert(region[record2+184]==1,'full-charge stall must scan beyond a healthy cached record')
        elseif scenario=='input-gap' or scenario=='input-expired' or scenario=='release-during-gap' then
            input_valid=false;tick();assert(writes==before,'unknown input must pause charge writes')
            if scenario=='input-expired' then ticks(40) end
            input_valid=true
            if scenario=='release-during-gap' then held_time=.01 end
            tick()
            if scenario=='input-gap' then
                assert(writes==before+1,'same held weapon must recover with its engine command cleared')
                down=false;before=writes;ticks(5);assert(writes==before,'release must immediately stop writes')
                down=true;ticks(20);assert(writes==before,'a new hold requires a new fire command')
            else
                ticks(20);assert(writes==before,'expired or interrupted hold must require a new fire command')
            end
        elseif scenario=='identity-gap' or scenario=='holder-gap' or scenario=='charge-binding-gap' then
            local address=scenario=='identity-gap' and WEAPON or scenario=='holder-gap' and 0x26000100+48+4 or CHARGE+16
            blocked[address]=true;tick();assert(writes==before,'unvalidated binding must pause writes')
            blocked[address]=nil;tick();assert(writes==before+1,'validated binding must resume without a new command')
        elseif scenario=='identity-change-during-gap' or scenario=='holder-change-during-gap' then
            input_valid=false;tick();input_valid=true
            if scenario=='identity-change-during-gap' then generation=2 else put(0x26000100+48+4,u(999)) end
            ticks(20);assert(writes==before,'changed identity or holder must not resume the old hold')
        elseif scenario=='diagnostic-recovery' then
            full_time=0;tick();full_time=1.2;ticks(230)
            charge=.8;tick();charge=0;tick();down=false;tick()
            local text=table.concat(log_text)
            local _,failures=text:gsub('idle: invalid full%-charge time','')
            assert(failures==1,'successful recovery must clear stale failure diagnostics')
            assert(text:find('released after 2 shot(s)',1,true),'first shot must be counted')
            assert(text:find('(1)',1,true),'first real shot interval must be included')
        else error('unknown recovery scenario '..scenario) end
    end
    print('PASS: recovery '..scenario..' ('..mode..'), bounded work and no render writes')
    return
end
local baseline_logs=logs
down=true
local before=reads
for _=1,100 do tick() end
assert(charge_reads==0 and writes==0,'ordinary weapons must not enumerate charged weapons or write')
assert(reads-before<=2500,'local input reads and throttled discovery must stay bounded')
assert(logs==baseline_logs,'ordinary clicks must not write idle diagnostics')
down=false;tick();weapon='arc';down=true
before=writes;tick()
assert(writes==before+1 and charge_reads==1,'first Arc press must resolve the active weapon and assist immediately')
for _=1,50 do tick() end
assert(writes==before+51,'one charge write per update, with continuous hold preserved')
charge=.8;tick();charge=0;command=false;tick();before=writes
for _=1,150 do tick() end
assert(writes-before==150,'a pause after the first shot must retain held input even after the one-shot command clears')
charge=.5;command=true
relocated=true;before=writes;tick()
assert(writes==before+1,'held fire must follow charge array relocation/compaction')
input_valid=false;before=writes;tick();assert(writes==before,'unavailable local input stops charge writes')
input_valid=true;tick();assert(writes==before+1,'valid local input recovers without reinstall')
generation=2;before=writes;tick();assert(writes==before,'reused entity address cannot keep the previous charge binding')
down=false;tick();down=true;tick();assert(writes==before+1,'new identity can arm only through current fire command')
put(0x26000100+48+4,u(999));before=writes;tick();assert(writes==before,'another player holder must not be assisted')
put(0x26000100+48+4,u(222))
down=false;before=writes;for _=1,50 do tick() end
assert(writes==before,'release stops writes')
second=true;down=true;tick()
assert(writes==before+1,'next press follows a second Arc Thrower')
assert(logs==baseline_logs,'normal holds and release must not flush verbose logs')
weapon='ordinary';before=writes;for _=1,20 do tick() end
assert(writes==before,'changed weapon identity cancels the cached entry')
print('PASS: native Fire action without mouse polling, local index one, charge relocation, missing-input recovery, bounded scanning, continuous firing, second weapon, release, no render duplication or routine log IO')
