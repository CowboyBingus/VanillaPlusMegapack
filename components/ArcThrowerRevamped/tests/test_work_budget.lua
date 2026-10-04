-- Synthetic supported image and weapon tables; all Windows calls are stubs.
local source=assert(arg[1])
local ffi=require('ffi')
local budget=dofile(((arg[0] or ''):match('^(.*)[/\\]') or '.')..'/frame_budget.lua')
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
local record_checks=0 -- 216-byte reads of a charge record (scan matches and revalidation)
local mode=arg[2] or 'normal'
local max_read, cost = 0, (mode=='normal' or mode=='budget') and 0 or 1200
local local_bytes={}
local function put(a,b)for i=1,#b do local_bytes[a+i-1]=b:sub(i,i)end end
local function u(v)return integer(v,'uint32_t')end
local PM,OWNER,AM,AVATAR=0x20000000,0x21000000,0x23000000,0x21f32f30
local input=AM+0x150+0xa7aec+0x1b68+9*32 -- local avatar is index one
local stale_input=nil -- a former local avatar's Fire slot: readable, never held
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
-- The local avatar moves to another index of the avatar manager (a respawn):
-- its old Fire slot stays readable and reads zero.
local function move_avatar(index)
    put(AM+0x110,integer(index==0 and AVATAR or 0));put(AM+0x118,integer(index==1 and AVATAR or 0))
    put(0x25000100+222%8*8,u(222)..u(index))
    stale_input=input
    input=AM+0x150+index*0xa7aec+0x1b68+9*32
end
local relocated, generation, input_valid, command=false,1,true,true
local aim=false -- the Aim slot (8) sits just before Fire; the assist never reads it
-- The engine copies each weapon's fire command into its charging flag every
-- frame and clears it once the shot fires: engine_flag is what the assist
-- reads at the start of its update (0: cleared, the assist must set it).
local engine_flag=0
local read_fault=false
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
local ZERO4='\0\0\0\0'
local function memory(address,size)
    if blocked[address] then return nil end
    if address==input+8 and size==4 then -- the idle gate's read: allocates nothing while Fire is up
        if not input_valid then return nil end
        return down and integer(held_time,'float') or ZERO4
    end
    if stale_input and address==stale_input+8 and size==4 then return ZERO4 end
    if address==input then return input_valid and blob(32,{[8]=integer(down and held_time or 0,'float')}) or nil end
    if address==input-32 then return blob(32,{[8]=integer(aim and held_time or 0,'float')}) end
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
        local b=ffi.new('uint8_t[40]');putf(b,4,charge);putf(b,8,full_time);b[12]=engine_flag
        return ffi.string(b,40)
    end
    return nil
end
local kernel={}
function kernel.GetModuleHandleA() return ffi.cast('void *',GAME) end
function kernel.GetCurrentProcess() return ffi.cast('void *',1) end
function kernel.QueryPerformanceFrequency(p) p[0]=1000000;return 1 end
function kernel.QueryPerformanceCounter(p) p[0]=clock%4294967296;p[1]=math.floor(clock/4294967296);return 1 end
function kernel.GetTickCount64() return math.floor(clock/1000) end
function kernel.ReadProcessMemory(_,address,buffer,size,count)
    if type(address)~='number' then address=tonumber(ffi.cast('uintptr_t',address)) end
    size=tonumber(size)
    reads,bytes=reads+1,bytes+size;max_read=math.max(max_read,size);clock=clock+cost
    if size==216 and address>=REGION and address<REGION+SIZE then record_checks=record_checks+1 end
    if read_fault and address==input+8 then error('injected read fault',0) end -- the addon's own error
    local data=memory(address,size)
    if mode=='stale' and size>216 and data and data:find(fingerprint,1,true) then
        ffi.fill(region+record+168,#fingerprint,0) -- allocation changed after the scan snapshot
    end
    if not data or #data~=size then return 0 end
    ffi.copy(buffer,data,size);count[0]=size;return 1
end
-- Page protection of the weapon data region (read-only unless changed) and of
-- the entry arrays (private read-write unless a test says otherwise). As on
-- Windows (measured in a test process), WriteProcessMemory fails on a
-- read-only page.
local PAGE=4096
local protections={}
local function region_protection(address) return protections[math.floor((address-REGION)/PAGE)] or 2 end
local entry_protection,entry_type,region_type=4,0x20000,0x20000
local entry_query_fails=false
local protect_fails,restore_fails=false,false
local protection_changes={} -- {address, new protection} in order
function kernel.VirtualQueryEx(_,address,info)
    queries=queries+1;clock=clock+cost
    if type(address)~='number' then address=tonumber(ffi.cast('uintptr_t',address)) end
    if address==0 then info.base=ffi.cast('void *',0);info.size=REGION;info.state=0;return 48 end
    if address>=REGION and address<REGION+SIZE then
        local base=address==REGION and REGION or address-(address-REGION)%PAGE
        info.base=ffi.cast('void *',base);info.size=REGION+SIZE-base
        info.state=0x1000;info.protection=region_protection(address);info.type=region_type;return 48
    end
    if address>=ENTRIES and address<ENTRIES+0x20000 then
        if entry_query_fails then return 0 end
        info.base=ffi.cast('void *',address-address%PAGE);info.size=PAGE
        info.state=0x1000;info.protection=entry_protection;info.type=entry_type;return 48
    end
    return 0
end
function kernel.VirtualProtectEx(_,address,size,protection,previous)
    if type(address)~='number' then address=tonumber(ffi.cast('uintptr_t',address)) end
    assert((address==REGION+record+184 or address==REGION+record2+184) and size==1,
           'protection changes only for a charge record flag')
    local restoring=protection~=4
    if (restoring and restore_fails) or (not restoring and protect_fails) then return 0 end
    local page=math.floor((address-REGION)/PAGE)
    previous[0]=protections[page] or 2
    protections[page]=tonumber(protection)
    protection_changes[#protection_changes+1]={address,tonumber(protection)}
    return 1
end
local record_writes={} -- {address, byte} in order
function kernel.WriteProcessMemory(_,address,data,size,written)
    if type(address)~='number' then address=tonumber(ffi.cast('uintptr_t',address)) end
    assert(size==1)
    local byte=ffi.string(data,1):byte()
    if address==REGION+record+184 or address==REGION+record2+184 then
        if region_protection(address)~=4 then return 0 end -- ERROR_NOACCESS on a read-only page
        record_writes[#record_writes+1]={address,byte}
        if byte==1 then patches=patches+1 end
        region[address-REGION]=byte
    else
        assert(byte==1,'the charging flag is only ever set')
        assert(address==entry_base()+slot()*40+12,'wrong weapon entry')
        writes=writes+1
    end
    written[0]=size;return 1
end
local counts=budget.wrap(kernel) -- per-frame Windows calls, for the budget mode
-- The addon reaches Windows only through its private names (atr1_*): each one
-- resolves to the stub of the real export, so counts keep the Windows names.
local private_kernel=setmetatable({},{__index=function(proxy,symbol)
    local name=type(symbol)=='string' and symbol:match('^atr1_(.+)$')
    if not (name and kernel[name]) then error('kernel32 used without a private name: '..tostring(symbol)) end
    rawset(proxy,symbol,kernel[name]) -- resolved once, like a native binding
    return kernel[name]
end})
local bindings=setmetatable({load=function(name)
    if name=='kernel32' then return private_kernel end
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
-- The update below this addon (the game's, or another mod's) can be made to
-- raise; the shutdown below it returns its arguments.
local below_raises,shutdowns=0,0
env.update=function(_,marker)
    assert(marker=='original');updates=updates+1
    if below_raises>0 then below_raises=below_raises-1;error('engine update failed',0) end
    return 1,nil,3
end
env.shutdown=function(...) shutdowns=shutdowns+1;return 'shut',... end
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
local startup=budget.frame(counts,tick) -- the first update: binding, build check and scan
for _=2,20 do tick() end
if mode=='stale' then
    assert(patches==0,'a stale fingerprint must never authorize a write')
    print('PASS: stale scan snapshot revalidated before writing')
    return
end
assert(patches==1 and max_read<=65536,'bounded scan must find a split fingerprint and patch exactly once')
if mode=='budget' then
    -- Exact Windows calls per frame and scenario (tests/frame_budget.lua). In
    -- game a ReadProcessMemory costs about 1-2 us and a VirtualQueryEx about
    -- 0.29 ms; the other calls are unmeasured in game. Limits equal today's
    -- exact counts: lowering one is welcome, raising one or adding a new kind
    -- of call needs a comment saying why.
    local report={}
    local function pin(label,limits,frame)
        frame=frame or budget.frame(counts,tick)
        budget.check(frame,limits,label)
        for name,n in pairs(limits) do
            assert((frame[name] or 0)==n,label..': '..name..' '..(frame[name] or 0)..', pinned '..n
                ..' (lower the pin when a call is saved)')
        end
        report[#report+1]=label..': '..budget.describe(frame)
    end
    -- Frames that revalidate the charge record (one 216-byte read) are pinned
    -- apart from the plain frames of the same scenario.
    local function settle()local c=record_checks;repeat tick() until record_checks>c end
    -- Pins the first of the next 100 frames for which found(frame) holds.
    local function first_frame(label,limits,found)
        for _=1,100 do
            local frame=budget.frame(counts,tick)
            if found(frame) then return pin(label,limits,frame) end
        end
        error(label..': no such frame within 100 frames')
    end
    local function check_frame(label,limits)
        local c=record_checks
        first_frame(label,limits,function() return record_checks>c end)
    end
    -- +1 VirtualQueryEx: the record page is checked right before its write.
    pin('startup scan and record patch',{GetModuleHandleA=2,GetCurrentProcess=1,QueryPerformanceFrequency=1,
        QueryPerformanceCounter=6,ReadProcessMemory=21,VirtualQueryEx=3,VirtualProtectEx=2,WriteProcessMemory=1},
        startup)
    assert(region_protection(REGION+record+184)==2,'the record page is read-only again after the patch')
    -- Every 15th update is a check frame: the record check (one 216-byte read)
    -- and the full Fire check (16 reads). Between them the idle gate reads the
    -- kept Fire slot once and stops while Fire is up.
    settle()
    pin('in a mission, fire up',{ReadProcessMemory=1})
    check_frame('in a mission, fire up, check frame',{ReadProcessMemory=17,QueryPerformanceCounter=1})
    aim=true;settle()
    pin('aiming, fire up',{ReadProcessMemory=1})
    aim=false
    put(GAME+0x3326468,integer(0));settle() -- no player manager: outside a mission
    pin('outside a mission',{})
    check_frame('outside a mission, check frame',{ReadProcessMemory=4,QueryPerformanceCounter=1})
    put(GAME+0x3326468,integer(PM));settle()
    down=true
    -- Between check frames the Fire check verifies the slot kept from the last
    -- check frame: the avatar manager global, the entity at the kept index and
    -- its 24-byte record (3 reads), then the input: 4 reads instead of 16. Any
    -- mismatch, and every check frame, resolves from the registry roots (16).
    -- +1 read on the frame a press starts: the gate's read, before the check;
    -- +5 there for the first discovery of the press.
    pin('first frame of a press, ordinary weapon',{ReadProcessMemory=10,QueryPerformanceCounter=1})
    pin('fire held, ordinary weapon',{ReadProcessMemory=4,QueryPerformanceCounter=1})
    -- Discovery retries ten times a second while the press finds no Arc Thrower.
    first_frame('fire held, ordinary weapon, discovery retry',{ReadProcessMemory=9,QueryPerformanceCounter=1},
        function(frame) return frame.ReadProcessMemory>4 end)
    down=false;pin('release, ordinary weapon',{ReadProcessMemory=4,QueryPerformanceCounter=1})
    -- Arc Thrower: until the first shot the engine copies its fire command
    -- into the charging flag every frame, so the assist reads it set and
    -- writes nothing. +1 read on the first frame: the gate's read.
    -- Held between check frames: the kept Fire check (4), the weapon identity
    -- (1), the kept weapon-holder row verified through the manager global, its
    -- rows pointer and the holder (3 instead of a 5-read lookup), the charge
    -- binding (3) and the entry (1): 12 reads instead of 26.
    settle();weapon='arc';engine_flag=1;down=true
    pin('first frame of an Arc Thrower press',{ReadProcessMemory=19,QueryPerformanceCounter=1})
    pin('Arc Thrower held, charging flag set by the engine',{ReadProcessMemory=12,QueryPerformanceCounter=1})
    -- After the shot the engine clears the flag every frame and the assist sets
    -- it again. The first write of a binding checks the entry's page: +1
    -- VirtualQueryEx (about 0.29 ms in game) once per binding, a new kind of
    -- call on this path, made because a write must not reach a page that is
    -- not private read-write data (WriteProcessMemory writes code pages too).
    engine_flag=0
    pin('first write of a binding: page check',{ReadProcessMemory=12,QueryPerformanceCounter=1,VirtualQueryEx=1,
        WriteProcessMemory=1})
    pin('Arc Thrower held after the shot',{ReadProcessMemory=12,QueryPerformanceCounter=1,WriteProcessMemory=1})
    check_frame('Arc Thrower held, check frame',{ReadProcessMemory=27,QueryPerformanceCounter=1,WriteProcessMemory=1})
    relocated=true -- the entry array moved to another page: checked again
    pin('entry moved to another page',{ReadProcessMemory=13,QueryPerformanceCounter=1,VirtualQueryEx=1,
        WriteProcessMemory=1})
    relocated=false;tick()
    down=false;pin('release, Arc Thrower',{ReadProcessMemory=4,QueryPerformanceCounter=1})
    -- The next press is a new binding: its page is checked again before its
    -- first write (here the engine has already cleared the flag).
    settle();down=true
    pin('first frame of the next press, flag clear',{ReadProcessMemory=19,QueryPerformanceCounter=1,
        VirtualQueryEx=1,WriteProcessMemory=1})
    down=false;tick()

    -- A cleared record flag is repaired on a check frame: one query, the
    -- page made writable and read-only again, one write and its read-back.
    region[record+184]=0
    check_frame('record repair',{ReadProcessMemory=18,QueryPerformanceCounter=1,VirtualQueryEx=1,
        VirtualProtectEx=2,WriteProcessMemory=1})
    assert(region[record+184]==1 and region_protection(REGION+record+184)==2,
           'the repaired record page is read-only again')
    -- A record page that is already private read-write is written directly.
    protections[math.floor((record+184)/PAGE)]=4;region[record+184]=0
    check_frame('record repair, page already writable',{ReadProcessMemory=18,QueryPerformanceCounter=1,
        VirtualQueryEx=1,WriteProcessMemory=1})
    protections[math.floor((record+184)/PAGE)]=nil
    assert(region[record+184]==1)
    weapon='ordinary';settle()
    weapon='ordinary';settle()

    -- An unreadable kept slot sends that frame to the Fire check (the kept
    -- slot verified, its input unreadable), which drops the slot; until the
    -- next check frame nothing is read.
    input_valid=false
    pin('kept Fire slot unreadable',{ReadProcessMemory=5,QueryPerformanceCounter=1})
    pin('no Fire slot known',{})
    input_valid=true;settle()
    pin('Fire slot found again on the check frame',{ReadProcessMemory=1})

    -- A respawn moves the local avatar to another index: its old slot stays
    -- readable and reads zero. The next check frame finds the new slot, so a
    -- press made right after the move arms within 15 updates (0.25 s at
    -- 60 FPS), still inside the press's first charge (about 1.1 s), which is
    -- the engine's own shot; worst case here: the press starts right after a
    -- check frame.
    weapon='arc';command=true;move_avatar(0);settle()
    move_avatar(1)
    local armed_after,before=nil,writes
    down=true
    for frame=1,15 do tick();if writes>before then armed_after=frame;break end end
    assert(armed_after,'a press after a respawn must arm by the next check frame')
    down=false;settle();weapon='ordinary'

    -- Idle frames allocate nothing: interpreted, and compiled once warm.
    local function idle_bytes()
        settle()
        collectgarbage('collect');collectgarbage('stop')
        local before=collectgarbage('count')
        for _=1,14 do tick() end
        local grown=(collectgarbage('count')-before)*1024
        collectgarbage('restart')
        return grown
    end
    jit.off()
    local interpreted=idle_bytes()
    jit.on()
    for _=1,3000 do tick() end
    local compiled=math.huge
    for _=1,5 do compiled=math.min(compiled,idle_bytes()) end -- a window where the JIT compiled nothing
    assert(interpreted==0 and compiled==0,
           'idle frames must allocate nothing: '..interpreted..' B interpreted, '..compiled..' B compiled')
    report[#report+1]='press right after a respawn armed on update '..armed_after
        ..'; idle frames allocate 0 B interpreted and compiled'

    -- Update-chain policy. The update below raises once: on the next update
    -- the addon puts the record back (one query, the page made writable and
    -- read-only again, the write and its read-back) and pauses; paused
    -- updates make no call; after 60 clean updates below it resumes on a
    -- check frame and patches the kept record again.
    below_raises=1;assert(not pcall(env.update,.01,'original'))
    pin('first update after an error below: record put back',{ReadProcessMemory=2,VirtualQueryEx=1,
        VirtualProtectEx=2,WriteProcessMemory=1})
    pin('paused',{})
    for _=1,58 do tick() end
    pin('resumed: check frame, record patched again',{ReadProcessMemory=18,QueryPerformanceCounter=1,
        VirtualQueryEx=1,VirtualProtectEx=2,WriteProcessMemory=1})
    -- Shutdown puts the record back; a stopped addon makes no call.
    pin('shutdown: record put back',{ReadProcessMemory=2,VirtualQueryEx=1,VirtualProtectEx=2,
        WriteProcessMemory=1},budget.frame(counts,env.shutdown))
    pin('after shutdown',{})
    assert(region[record+184]==0 and region_protection(REGION+record+184)==2)
    print('PASS: per-frame Windows calls pinned in '..#report..' scenarios\n  '..table.concat(report,'\n  '))
    return
end
if scenario then
    local function ticks(n)for _=1,n do tick()end end
    if scenario=='large-trigger-table' or scenario=='sparse-trigger-table' then
        trigger_count=scenario=='large-trigger-table' and 65 or 4096
        trigger_slot=trigger_count-1;down=true;weapon='arc'
        tick();assert(writes==1,'active Arc at the end of a sparse table must arm on first discovery')
        down=false;tick();local before=writes;trigger_count=0xffffffff;down=true;ticks(30)
        assert(writes==before,'corrupt table size must not authorize writes')
    elseif scenario=='entry-query-failed' then
        -- The protection query itself fails: nothing is written, the addon
        -- stops and the log says the query failed.
        entry_query_fails=true;weapon='arc';engine_flag=0;down=true;ticks(30)
        assert(writes==0 and region[record+184]==0,'no write when the page cannot be checked; record put back')
        assert(table.concat(log_text):find('is not private read-write memory (protection query failed)',1,true))
    elseif scenario=='entry-refused' then
        -- The charging flag's page is executable code, not private read-write
        -- data: WriteProcessMemory would write it anyway, so the check must.
        -- The refusal stops the addon, which puts the record back.
        entry_protection=0x20;weapon='arc';engine_flag=0;down=true;ticks(30)
        assert(writes==0,'a charging flag outside private read-write data is never written')
        local _,stops=table.concat(log_text):gsub('ArcThrowerRevamped stopped: charge entry 0x%x+ is not private read%-write memory','')
        assert(stops==1,'the refusal stops the addon, logged once')
        assert(table.concat(log_text):find('memory (state 0x1000, protection 0x20, type 0x20000)',1,true),
               "the refusal names the page's state, protection and type")
        assert(region[record+184]==0 and region_protection(REGION+record+184)==2,
               'stopping puts the record flag back, read-only')
        entry_protection=4;down=false;ticks(5);down=true;ticks(30)
        assert(writes==0 and region[record+184]==0,'a stopped addon writes nothing')
        env.shutdown()
        assert(table.concat(log_text):find('Shutdown: stopped after: charge entry',1,true),
               'the refusal is the first failure at shutdown')
    elseif scenario=='record-protection-refused' or scenario=='record-not-private'
        or scenario=='record-restore-failed' then
        if scenario=='record-protection-refused' then protect_fails=true
        elseif scenario=='record-not-private' then region_type=0x40000 -- MEM_MAPPED
        else restore_fails=true end
        local changes=#protection_changes
        env.ArcThrowerDiagnostics=scenario~='record-restore-failed' or nil -- the repair log names the reason
        region[record+184]=0;ticks(30)
        env.ArcThrowerDiagnostics=nil
        if scenario=='record-restore-failed' then
            -- The flag was written, the page stayed writable: the addon stops
            -- and puts the flag back through the still-writable page.
            local text=table.concat(log_text)
            assert(text:find('could not be made read-only again',1,true)
                   and text:find('ArcThrowerRevamped stopped: weapon data protection could not be restored',1,true),
                   'a failed restore is logged and stops the addon')
            assert(region[record+184]==0,'stopping put the record flag back')
            local before=writes;weapon='arc';down=true;ticks(20)
            assert(writes==before and region[record+184]==0,'a stopped addon writes nothing')
        else
            assert(region[record+184]==0 and #protection_changes==changes,
                   'a refused page or protection change writes nothing and changes no protection')
            local why=scenario=='record-protection-refused' and 'record page protection could not be changed'
                or 'record page is not private read-only memory (state 0x1000, protection 0x2, type 0x40000)'
            assert(table.concat(log_text):find('charge record repair failed ('..why..'); retrying',1,true),
                   'the diagnostics log names why the record could not be written')
            assert(region_protection(REGION+record+184)==2)
            protect_fails=false;region_type=0x20000;ticks(30)
            assert(region[record+184]==1 and region_protection(REGION+record+184)==2,
                   'the record is repaired, read-only again, once the page qualifies')
        end
    elseif scenario=='update-error-pause' then
        -- The update below raises once: its error reaches the caller unchanged;
        -- on the next update the addon ends the hold, puts the record back and
        -- pauses until the updates below have returned 60 times in a row.
        weapon='arc';engine_flag=0;down=true;ticks(3);local armed_writes=writes
        assert(armed_writes>0)
        below_raises=1
        local ok,problem=pcall(env.update,.01,'original')
        assert(not ok and problem=='engine update failed','the error below passes through unchanged')
        assert(region[record+184]==1,'nothing is restored before the next update')
        armed_writes=writes -- that frame's step ran before the update below raised
        for _=1,60 do tick() end
        assert(writes==armed_writes,'no charging-flag write while paused')
        assert(region[record+184]==0 and region_protection(REGION+record+184)==2,'paused with the record put back')
        local text=table.concat(log_text)
        assert(text:find('ArcThrowerRevamped paused: the previous update failed',1,true) and not text:find('resumed',1,true))
        tick() -- the 60th clean update below has returned: resume, patch the kept record again
        assert(table.concat(log_text):find('ArcThrowerRevamped resumed after 60 clean frames',1,true))
        assert(region[record+184]==1 and region_protection(REGION+record+184)==2,'patched again after resuming')
        down=false;tick();down=true;ticks(3)
        assert(writes>armed_writes,'the assist works again after a new press')
    elseif scenario=='update-errors-stop' then
        -- Eight errors below in one burst stop the addon for the session.
        for _=1,8 do below_raises=1;pcall(env.update,.01,'original');tick() end
        local text=table.concat(log_text)
        local _,pauses=text:gsub('ArcThrowerRevamped paused: the previous update failed','')
        assert(pauses==1,'one log line for the burst of errors below')
        assert(text:find('ArcThrowerRevamped stopped: stopped after 8 failed updates below this mod',1,true))
        assert(region[record+184]==0,'stopping put the record back')
        weapon='arc';down=true;ticks(20)
        assert(writes==0,'a stopped addon writes nothing')
        local a,b,c=env.shutdown('x',7)
        assert(a=='shut' and b=='x' and c==7 and shutdowns==1,'the shutdown below runs with its arguments')
        assert(table.concat(log_text):find('Shutdown: stopped after: stopped after 8 failed updates below this mod',1,true))
    elseif scenario=='own-errors' then
        -- The addon's own errors: one log line per burst; a count starts again
        -- after 3600 error-free updates; 8 in one burst stop it.
        local function errors(n) read_fault=true;for _=1,n do tick() end;read_fault=false end
        errors(7);ticks(3600);errors(7);ticks(10)
        local _,bursts=table.concat(log_text):gsub('ArcThrowerRevamped error: injected read fault','')
        assert(bursts==2 and not table.concat(log_text):find('stopped',1,true),
               'two bursts of 7 errors, an error-free minute apart, do not stop the addon')
        errors(8)
        assert(table.concat(log_text):find('ArcThrowerRevamped stopped: stopped after 8 errors: injected read fault',1,true))
        assert(region[record+184]==0,'stopping put the record back')
    elseif scenario=='shutdown-restore' then
        -- At shutdown the record flag goes back, read-only; the shutdown below
        -- runs with its arguments and its results come back.
        weapon='arc';down=true;ticks(5)
        local a,b,c=env.shutdown('x',7)
        assert(a=='shut' and b=='x' and c==7 and shutdowns==1)
        assert(region[record+184]==0 and region_protection(REGION+record+184)==2)
        assert(table.concat(log_text):find('Shutdown: stopped\n',1,true),'a clean session reports plain "stopped"')
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
-- Between check frames the kept Fire slot is verified by its avatar record: a
-- changed local avatar at the kept index ends the hold on the next frame.
weapon='arc';second=false;command=true;down=false;tick();down=true;before=writes;tick()
assert(writes==before+1,'a new press arms')
put(AVATAR+16,u(5));before=writes;tick()
assert(writes==before,'a changed local avatar ends the hold at once')
put(AVATAR+16,u(0));down=false;tick()
-- The kept weapon-holder row is re-read every frame and looked up afresh on
-- every check frame: a weapon moved to another holder row (here another
-- player's) ends the hold by the next check frame at the latest.
down=true;tick();before=writes;tick();assert(writes==before+1,'armed again')
put(0x25000200+77%8*8,u(77)..u(2));put(0x26000100+96+4,u(999))
local checks=record_checks
repeat tick() until record_checks>checks
before=writes;tick();assert(writes==before,'the check frame looks the holder up afresh')
put(0x25000200+77%8*8,u(77)..u(1));down=false;tick()
print('PASS: native Fire action without mouse polling, local index one, charge relocation, missing-input recovery, bounded scanning, continuous firing, second weapon, release, no render duplication or routine log IO')
