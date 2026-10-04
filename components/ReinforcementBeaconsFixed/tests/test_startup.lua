-- Exercise the real snapshot reader, correction and update wrapper across startup.
local source=assert(arg[1])
local ffi=require('ffi')
local patch=assert(loadfile(source..'/spawn_data.lua'))()
local game,exe,pm,mode,entity,rm,pos,entities,used,hash,coordinates=
    0x10000000,0x20000000,0x30000000,0x40000000,0x50000000,0x60000000,
    0x70000000,0x71000000,0x72000000,0x73000000,0x74000000
local regions={}
local function region(address,size)
    local data=ffi.new('uint8_t[?]',size)
    regions[#regions+1]={address=address,size=size,data=data}
    return data
end
local globals={}
for _,rva in ipairs({0x3326468,0x33266a0,0x33269c0,0x3326b20}) do
    globals[rva]=region(game+rva,8)
end
local p,m,e,r,q=region(pm,0x440),region(mode,0x44),region(entity,24),region(rm,0x58),region(pos,0x60)
local es,us,hs,xyz=region(entities,8),region(used,4),region(hash,64),region(coordinates,12)
local function set(data,offset,ctype,value) ffi.copy(data+offset,ffi.new(ctype..'[1]',value),ffi.sizeof(ctype)) end
local function pointer(data,offset,value) set(data,offset,'uint64_t',value) end
local function integer(data,offset,value) set(data,offset,'uint32_t',value) end
local function number(data,offset,value) set(data,offset,'float',value) end
local function locate(address,size)
    for _,row in ipairs(regions) do
        if address>=row.address and address+size<=row.address+row.size then return row.data+address-row.address end
    end
    error('Unbounded fixture read '..string.format('%x',address))
end
local writes,unreadable=0,false
local api={module=function(name)return name and game or exe end,module_hash=function(module)return tostring(module) end}
api.read=function(address,size)
    if unreadable and address==pm then return nil end
    return ffi.string(locate(address,size),size)
end
-- Like the real adapter: all bytes into the caller's buffer, or false.
api.read_into=function(address,size,buffer)
    if unreadable and address==pm then return false end
    ffi.copy(buffer,locate(address,size),size);return true
end
local function decode(bytes,offset)
    if not bytes then return nil end
    local v=ffi.new('uint64_t[1]');ffi.copy(v,bytes:sub((offset or 0)+1),8)
    local n=tonumber(v[0]);if n<0x10000 or n>=0x800000000000 then return nil end
    return n
end
api.pointer=decode
api.pointer_at=function(buffer,offset) return decode(ffi.string(buffer+offset,8)) end
api.writable_data=function(address,size)return address>=pm and address+size<=pm+0x440 end
-- Like the real adapter, write checks protection itself right before writing.
api.write=function(address,bytes)
    assert(address==pm+0x10c and #bytes==8,'Only the pending XY may be changed')
    if not api.writable_data(address,#bytes) then return false end
    writes=writes+1;ffi.copy(locate(address,8),bytes,8);return true
end
local env=setmetatable({print=function()end,os={getenv=function()end},CowboyBingusModLoader={api=1},
    update=function(...)return ... end},{__index=_G});env._G=env
-- The build hands the loader the vendored runtime as the fourth argument.
local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
local install=setfenv(assert(loadfile(source..'/archive_loader.lua'))(),env)
install(function()return api end,patch,{revision='startup-test',game_sha256=tostring(game),exe_sha256=tostring(exe)},
    runtime)
local function update()
    local a,b,c=env.update(0.1,nil,'sentinel')
    assert(a==0.1 and b==nil and c=='sentinel','Original update results changed')
end
update();update()
assert(env.ReinforcementBeaconFixData.status:find('waiting_for_game_data',1,true),
    'Null startup pointer became a permanent failure: '..env.ReinforcementBeaconFixData.status)
assert(writes==0)
pointer(globals[0x3326468],0,pm)
integer(p,0x84,2);integer(p,0x88,2);integer(p,0x2e0,3);integer(p,0x3a8,0x7fff)
number(p,0x12c,5);number(p,0x114,321)
update();assert(writes==0)
pointer(globals[0x33266a0],0,mode)
update() -- Ship/mission mode has not initialized.
integer(m,8,1);integer(m,0x40,1)
update() -- Player entity has not initialized.
pointer(p,0xe8,entity);integer(e,8,5);e[20]=1
update() -- Reinforcement manager has not initialized.
pointer(globals[0x33269c0],0,rm);pointer(globals[0x3326b20],0,pos)
update();assert(writes==0)
unreadable=true;update();assert(writes==0);unreadable=false
update() -- An unreadable transition must also recover.
pointer(r,0x38,entities);pointer(r,0x48,used);pointer(es,0,entity)
integer(e,8,77);integer(p,0x2e0,1);integer(r,8,1);integer(r,12,1)
pointer(q,0x28,hash);integer(q,0x30,8);integer(q,0x34,0xffffffff);integer(q,0x38,1)
integer(q,8,1);pointer(q,0x50,coordinates)
for i=0,7 do integer(hs,8*i,0xffffffff) end
integer(hs,8*5,77);integer(hs,8*5+4,0)
number(xyz,0,11);number(xyz,4,22);number(xyz,8,33)
number(p,0x10c,50);number(p,0x110,60)
update() -- Capture the unused beacon and the new local identity.
integer(p,0x2e0,2);integer(us,0,1)
update()
assert(writes==1 and env.ReinforcementBeaconFixData.corrections==1,'Did not recover and correct reinforcement')
assert(ffi.cast('float*',p+0x10c)[0]==11 and ffi.cast('float*',p+0x110)[0]==22)
assert(ffi.cast('float*',p+0x114)[0]==321 and ffi.cast('float*',p+0x12c)[0]==5)
-- Teardown/reload must discard cached associations, including a previously centered spawn.
pointer(globals[0x3326468],0,0);update()
pointer(globals[0x3326468],0,pm);update();assert(writes==1)
integer(p,0x2e0,3);update()
integer(p,0x2e0,1);integer(us,0,0);update()
integer(p,0x2e0,2);integer(us,0,1);number(p,0x10c,50);number(p,0x110,60);update()
assert(writes==2)
-- Real reader + wrapper: a remote beacon may appear in the queue-commit frame
-- with only its owner's bit set (2), while the local player's bit remains 0.
local remote_address=0x51000000
local remote=region(remote_address,24);integer(remote,8,77)
pointer(es,0,remote_address)
integer(p,0x2e0,3);integer(r,12,0);update()
integer(p,0x2e0,1);update()
integer(r,12,1);integer(us,0,2);integer(p,0x2e0,2)
number(p,0x10c,50);number(p,0x110,60);update()
assert(writes==3 and env.ReinforcementBeaconFixData.last.association=='unmarked_remote')
assert(ffi.cast('float*',p+0x10c)[0]==11 and ffi.cast('float*',p+0x110)[0]==22)
assert(ffi.cast('uint32_t*',us)[0]==2 and remote[20]==0,'Beacon ownership/use flags changed')
assert(ffi.cast('float*',p+0x114)[0]==321 and ffi.cast('float*',p+0x12c)[0]==5)
-- A non-null invalid layout remains fatal; retries apply only to unavailable data.
for kind=1,7 do
    integer(m,0x40,kind);integer(p,0x2e0,3);integer(r,12,0);update()
    integer(p,0x2e0,1);update()
    local before=writes
    integer(r,12,1);integer(us,0,2);integer(p,0x2e0,2)
    number(p,0x10c,50);number(p,0x110,60);update()
    assert(writes==before+1,'reader/writer rejected mission mode '..kind)
end
local completed_writes=writes
-- Build 25327279's automatic reinforcement producer compares and creates type
-- 0x7C (ACCC96 / ACCEC5). Type 0x7A now belongs to another stratagem. Exercise
-- the real reader and wrapper, rather than feeding preclassified plan rows.
local sm,automatic,camera,owner=0x75000000,0x76000000,0x77000000,0x78000000
local stratagems=region(sm,0x80);local rows=region(automatic,128);local cam=region(camera,0x48)
for rva,address in pairs({[0x33266b0]=sm,[0x346d560]=camera,[0x346bf98]=owner}) do
    pointer(region(game+rva,8),0,address)
end
pointer(stratagems,0x78,automatic)
integer(p,0x84,1);integer(p,0x88,1);integer(p,0x2e0,3);integer(r,12,0)
integer(m,0x40,1);integer(stratagems,0x34,0);integer(p,0x3a8,0x7fff)
number(cam,0x3c,11);number(cam,0x40,22);number(cam,0x44,3)
update()
integer(p,0x2e0,1);update()
integer(stratagems,0x34,1);integer(rows,12,0x7a)
number(rows,16,70);number(rows,20,80);number(rows,24,30)
assert(#patch.snapshot(api,game,exe).automatic==0,'Obsolete auto-anchor type was accepted')
update();assert(not env.ReinforcementBeaconFixData.anchor and writes==completed_writes)
integer(stratagems,0x34,2);integer(rows,64+12,0x7c)
number(rows,64+16,90);number(rows,64+20,100);number(rows,64+24,30)
local current=patch.snapshot(api,game,exe)
assert(#current.automatic==1 and current.automatic[1].position[1]==90,
    'Current automatic reinforcement anchor was not recognized')
update()
assert(env.ReinforcementBeaconFixData.anchor and env.ReinforcementBeaconFixData.anchor.source[1]==11)
-- Moving the source later must not move the saved death anchor. The queue is
-- scattered again around its beacon; only XY is restored to the frozen source.
number(cam,0x3c,500);number(cam,0x40,600)
pointer(es,0,entity);integer(e,8,77);e[20]=1
integer(r,12,1);integer(us,0,1);number(xyz,0,90);number(xyz,4,100)
integer(p,0x2e0,2);number(p,0x10c,120);number(p,0x110,130)
update()
assert(writes==completed_writes+1 and env.ReinforcementBeaconFixData.last.kind=='solo')
assert(ffi.cast('float*',p+0x10c)[0]==11 and ffi.cast('float*',p+0x110)[0]==22,
    'Solo correction followed the scattered beacon or moving source')
assert(ffi.cast('float*',p+0x114)[0]==321 and ffi.cast('float*',p+0x12c)[0]==5)
assert(ffi.cast('uint32_t*',us)[0]==1 and e[20]==1,'Solo correction changed use flags or ownership')
update();assert(writes==completed_writes+1,'Solo correction repeated for the same queue')
integer(p,0x2e0,3);integer(r,12,0);integer(stratagems,0x34,0);update()
assert(not env.ReinforcementBeaconFixData.anchor and not env.ReinforcementBeaconFixData.pending)
-- Per-frame call budget through the update wrapper: one check per frame, two
-- while a reinforcement is in progress. Only the correction frame queries
-- memory protection (about 0.29 ms in game), once, inside its single write.
do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local counts=budget.wrap(api)
    local function check(label,limits,status,corrected)
        local before=writes
        local frame=budget.frame(counts,update)
        local state=env.ReinforcementBeaconFixData
        assert(state.status:find(status,1,true) and writes==before+(corrected or 0),label..': '..state.status)
        budget.check(frame,limits,label)
    end
    -- Every read is one ReadProcessMemory: read_into fills a buffer the mod
    -- keeps (no string per read), pointer_at decodes an address from it, and
    -- api.read remains only for the write's read-back. The mode is read first,
    -- so the ship stops after two reads; the price is that a missing player
    -- manager during a gameplay mode (this fixture) costs 3 reads instead of 1.
    pointer(globals[0x3326468],0,0)
    check('loading',{read_into=3,pointer_at=1},'waiting_for_game_data')
    pointer(globals[0x3326468],0,pm);integer(m,8,0)
    check('on the ship',{read_into=2,pointer_at=1},'waiting_for_reinforcement')
    -- Alive with one beacon out: the beacon records are still read, because a
    -- 3 -> 2 transition compares against their use bits; their positions only
    -- in states 1 and 2.
    integer(m,8,1);integer(p,0x84,2);integer(p,0x88,2);integer(r,12,1);integer(us,0,0)
    check('alive in a mission',{read_into=10,pointer_at=7},'waiting_for_reinforcement')
    integer(p,0x2e0,1)
    check('reinforcement queued',{read_into=28,pointer_at=20},'waiting_for_reinforcement')
    -- Snapshot, fresh re-read, the write with its one protection query (the
    -- fixture's write makes it, as the real adapter does), read-back; then the
    -- repeat check. A separate check before the write made it two queries.
    integer(p,0x2e0,2);integer(us,0,1);number(p,0x10c,50);number(p,0x110,60)
    check('correction write',{read_into=42,read=1,pointer_at=30,writable_data=1,write=1},
        'reinforcement_already_centered',1)
    check('correction held',{read_into=28,pointer_at=20},'reinforcement_already_centered')
    integer(p,0x84,1);integer(p,0x88,1);integer(p,0x2e0,3);integer(r,12,0)
    check('alive solo',{read_into=9,pointer_at=5},'waiting_for_reinforcement')
    -- Solo death: the source position (here the fallback, 3 reads) is read
    -- only in the check that captures a new automatic anchor, then never again
    -- for that anchor.
    integer(p,0x2e0,1);integer(stratagems,0x34,1);integer(rows,12,0x7c)
    number(rows,16,90);number(rows,20,100);number(rows,24,30)
    check('solo anchor captured',{read_into=23,pointer_at=14},'waiting_for_reinforcement')
    assert(env.ReinforcementBeaconFixData.anchor and env.ReinforcementBeaconFixData.anchor.source[1]==500)
    check('solo anchor held',{read_into=20,pointer_at=12},'waiting_for_reinforcement')
    integer(p,0x2e0,3);integer(stratagems,0x34,0);update()
end
completed_writes=writes
integer(p,0x84,99);update()
assert(env.ReinforcementBeaconFixData.status:find('Unsupported player layout',1,true))
integer(p,0x84,2);integer(p,0x2e0,1);integer(us,0,0);update()
integer(p,0x2e0,2);integer(us,0,1);update();assert(writes==completed_writes)
pointer(globals[0x3326468],0,1)
local ok,message=pcall(patch.snapshot,api,game,exe)
assert(not ok and tostring(message):find('Invalid spawn data pointer',1,true),'Invalid non-null pointer treated as startup')
print('PASS: per-frame call budget: no protection query outside the correction frame; 10 reads alive in a mission')
print('PASS: null startup, staged initialization, unreadable transition, correction, mission reload and fatal-layout protection')
-- The update chain on the runtime guard, through fresh installs over the same
-- fixture. An error below pauses the mod: a pending correction that still holds
-- its bytes is put back and every association is forgotten; 60 clean updates
-- below resume it. 8 errors below in a burst stop it; own errors are counted
-- per burst; a refusal stops it at once; shutdown writes nothing.
do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local counts=budget.wrap(api)
    local failing=false
    local function guarded(target,printer)
        local host=setmetatable({print=printer or function()end,os={getenv=function()end},
            CowboyBingusModLoader={api=1},shutdowns=0},{__index=_G})
        host._G=host
        host.update=function(...) if failing then error('update below failed',0) end return ... end
        host.shutdown=function() host.shutdowns=host.shutdowns+1 end
        setfenv(assert(loadfile(source..'/archive_loader.lua'))(),host)(function()return api end,target or patch,
            {revision='guard-test',game_sha256=tostring(game),exe_sha256=tostring(exe)},runtime)
        return host,host.BingusRuntime.statuses.ReinforcementBeaconsFixed
    end
    local function frame(host)
        local a,b,c=host.update(0.1,nil,'sentinel')
        assert(a==0.1 and b==nil and c=='sentinel','Original update results changed')
    end
    local function fail_below(host)
        failing=true
        assert(not pcall(host.update,0.1),'the error below reaches the caller')
        failing=false
    end
    local function xy() return ffi.cast('float*',p+0x10c)[0],ffi.cast('float*',p+0x110)[0] end
    -- A two-player mission with one locally owned beacon: alive, queued, corrected.
    local function corrected(host)
        pointer(globals[0x3326468],0,pm);integer(m,8,1);integer(m,0x40,1)
        integer(p,0x84,2);integer(p,0x88,2);integer(p,0x3a8,0x7fff)
        pointer(es,0,entity);integer(e,8,77);e[20]=1;integer(r,12,1)
        number(xyz,0,11);number(xyz,4,22);number(xyz,8,33)
        integer(p,0x2e0,3);integer(us,0,0);frame(host)
        integer(p,0x2e0,1);frame(host)
        local before=writes
        integer(p,0x2e0,2);integer(us,0,1);number(p,0x10c,50);number(p,0x110,60);frame(host)
        local x,y=xy()
        assert(writes==before+1 and x==11 and y==22,'correction written')
    end

    local host,status=guarded()
    corrected(host)
    fail_below(host)
    local before=writes
    local pause=budget.frame(counts,frame,host)
    -- The restore: the player manager, the spawn state, the XY, one checked
    -- eight-byte write (one protection query) and its read-back, once per pause.
    budget.check(pause,{read=4,pointer=1,writable_data=1,write=1},'pause with a pending correction')
    local x,y=xy()
    assert(x==50 and y==60 and writes==before+1,'the original XY is back')
    assert(status.state=='paused: the previous update failed' and status.pauses==1)
    local mod=host.ReinforcementBeaconFixData
    assert(mod.status=='paused: the previous update failed; correction_restored' and not mod.active)
    assert(not mod.pending and not mod.previous and not mod.anchor,'a fresh start')
    for _=1,59 do budget.check(budget.frame(counts,frame,host),{},'paused') end
    frame(host)
    assert(status.state=='running' and writes==before+1,'resumed; the same queue is not corrected again')
    assert(mod.status=='beacon_association_unavailable',mod.status)

    host,status=guarded()
    corrected(host)
    before=writes
    for i=1,40 do failing=i%2==1;pcall(host.update,0.1) end
    failing=false
    assert(status.state=='stopped: stopped after 8 failed updates below this mod' and status.pauses==1
        and status.lower_errors==8 and writes==before+1,status.state)
    frame(host);assert(writes==before+1)
    host.shutdown()
    assert(host.shutdowns==1 and status.state=='stopped after: stopped after 8 failed updates below this mod')

    -- Own errors (here a failing print while the status changes every check)
    -- are counted per burst: a clean minute ends one, the 8th of a burst stops.
    local n,raising=0,false
    local chatty={apply=function() n=n+1;return true,'check '..n,false end,restore=patch.restore}
    host,status=guarded(chatty,function() if raising then error('print failed',0) end end)
    raising=true
    for _=1,7 do frame(host) end
    assert(status.errors==7 and status.state=='running')
    raising=false
    for _=1,3600 do frame(host) end
    assert(status.errors==0)
    raising=true
    for _=1,7 do frame(host) end
    assert(status.errors==7 and status.state=='running')
    frame(host)
    assert(status.state=='stopped: stopped after 8 errors: print failed',status.state)
    -- Errors below separated by a clean minute never stop the mod.
    host,status=guarded({apply=function() return true,'waiting_for_reinforcement',false end,restore=patch.restore})
    for i=1,3700*10+61 do failing=i%3700==0 and i<=3700*10;pcall(host.update,0.1) end
    failing=false
    assert(status.pauses==10 and status.state=='running' and status.lower_errors<=1,status.state)

    -- A refusal stops the mod at once and puts back its pending correction.
    host,status=guarded()
    corrected(host)
    before=writes
    integer(p,0x84,99);frame(host)
    assert(status.state:find('^stopped: .*Unsupported player layout'),status.state)
    x,y=xy()
    assert(x==50 and y==60 and writes==before+1,'the original XY is back')
    integer(p,0x84,2);frame(host);assert(writes==before+1,'stopped for good')
    -- A pause whose restore cannot write stops the mod.
    host,status=guarded()
    corrected(host)
    local checked=api.writable_data
    api.writable_data=function() return false end
    fail_below(host);frame(host)
    api.writable_data=checked
    assert(status.state=='stopped: pause failed: correction_restore_failed',status.state)
    x,y=xy();assert(x==11 and y==22)
    -- Shutdown writes nothing; a pending correction stays as written.
    host,status=guarded()
    corrected(host)
    before=writes
    host.shutdown()
    x,y=xy()
    assert(host.shutdowns==1 and status.state=='stopped' and writes==before and x==11 and y==22)
end
print('PASS: update guard: an error below pauses with the pending correction restored and resumes afresh; '
    ..'8 below or 8 own errors in a burst stop; a refusal stops and restores; shutdown writes nothing')
-- The game replaces tostring: every cdata prints as '[cdata (deleted)]'. With
-- that tostring and pointers as cdata (as the runtime's pointer returns them), a
-- player manager that changes must still be noticed, both against the previous
-- snapshot and in the re-read right before the write. Two managers with the same
-- bytes at different addresses: only the address tells them apart.
do
    local game_env=setmetatable({tostring=function(value)
        if type(value)=='cdata' then return '[cdata (deleted)]' end
        return tostring(value)
    end},{__index=_G})
    local in_game=setfenv(assert(loadfile(source..'/spawn_data.lua')),game_env)()
    local pm2=0x31000000
    local p2=region(pm2,0x440)
    local function number_of(address)
        return type(address)=='cdata' and tonumber(ffi.cast('uintptr_t',address)) or address
    end
    local written={}
    local global_reads,swap_at=0,nil
    local cdata_api={module=api.module,module_hash=api.module_hash}
    cdata_api.pointer=function(bytes,offset)
        local value=api.pointer(bytes,offset)
        return value and ffi.cast('uint8_t *',value)
    end
    cdata_api.pointer_at=function(buffer,offset)
        local value=api.pointer_at(buffer,offset)
        return value and ffi.cast('uint8_t *',value)
    end
    cdata_api.read=function(address,size)
        return api.read(number_of(address),size)
    end
    cdata_api.read_into=function(address,size,buffer)
        address=number_of(address)
        if address==game+0x3326468 then
            global_reads=global_reads+1
            if global_reads==swap_at then ffi.copy(buffer,ffi.new('uint64_t[1]',pm2),8);return true end
        end
        return api.read_into(address,size,buffer)
    end
    -- Either manager's pending XY is writable here, so a write into the wrong one
    -- is recorded instead of refused.
    cdata_api.writable_data=function(address,size)
        address=number_of(address)
        return (address==pm+0x10c or address==pm2+0x10c) and size==8
    end
    cdata_api.write=function(address,bytes)
        address=number_of(address)
        if not cdata_api.writable_data(address,#bytes) then return false end
        written[#written+1]=address;ffi.copy(locate(address,8),bytes,8);return true
    end
    -- A two-player mission with one locally owned beacon, queued (state 1).
    local function queued()
        pointer(globals[0x3326468],0,pm);integer(m,8,1);integer(m,0x40,1)
        integer(p,0x84,2);integer(p,0x88,2);integer(p,0x3a8,0x7fff);number(p,0x12c,5)
        pointer(p,0xe8,entity);pointer(es,0,entity);integer(e,8,77);e[20]=1;integer(r,12,1)
        number(xyz,0,11);number(xyz,4,22);number(xyz,8,33)
        integer(p,0x2e0,1);integer(us,0,0);number(p,0x10c,50);number(p,0x110,60)
    end
    local function committed()
        integer(p,0x2e0,2);integer(us,0,1)
        ffi.copy(p2,p,0x440)
    end
    -- 1. Against the previous snapshot: queued in one manager, committed in another.
    queued()
    local tracker={}
    assert(in_game.apply(cdata_api,game,exe,tracker))
    committed()
    pointer(globals[0x3326468],0,pm2)
    local ok,reason=in_game.apply(cdata_api,game,exe,tracker)
    assert(ok and reason=='waiting_for_reinforcement' and #written==0,
        'a changed player manager went unnoticed against the previous snapshot: '..tostring(reason))
    -- 2. In the re-read right before the write: the manager changes between the two.
    queued()
    tracker={}
    assert(in_game.apply(cdata_api,game,exe,tracker))
    committed()
    global_reads,swap_at=0,2
    ok,reason=in_game.apply(cdata_api,game,exe,tracker)
    swap_at=nil
    assert(ok and reason=='spawn_changed_before_write' and #written==0,
        'a changed player manager went unnoticed before the write: '..tostring(reason))
    -- The same manager throughout: the correction is made, once.
    queued()
    tracker={}
    assert(in_game.apply(cdata_api,game,exe,tracker))
    committed()
    ok,reason=in_game.apply(cdata_api,game,exe,tracker)
    assert(ok and reason=='beacon_spawn_centered' and #written==1 and written[1]==pm+0x10c,tostring(reason))
    assert(ffi.istype('uint8_t *',tracker.previous.identity),'the identity is the pointer itself')
end
print('PASS: under the game\'s tostring, a changed player manager is noticed against the previous snapshot '
    ..'and before the write')
-- The real Windows adapter over the vendored runtime, in this process only:
-- module hashes read once per session, refused module pages, an eight-byte
-- write and read-back in Lua-owned memory, pointer decoding and distance.
do
    local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
    local create=assert(loadfile(source..'/windows_api.lua'))()
    assert(not pcall(create),'The adapter needs the runtime')
    local real=create(runtime,assert(loadfile(source..'/bingus_write.lua'))().extend(assert(loadfile(source..'/bingus_memory.lua'))().new(runtime)))
    local image=real.module(nil)
    local hash=real.module_hash(image)
    local hashed=rawget(_G,'BingusRuntime').hash_reads
    assert(#hash==64 and real.module_hash(image)==hash and rawget(_G,'BingusRuntime').hash_reads==hashed)
    assert(real.read(ffi.cast('void *',1),8)==nil)
    assert(not real.writable_data(image,8) and not real.write(image,string.rep('\0',8)))
    local cell=ffi.new('uint8_t[16]')
    local xy=ffi.string(ffi.new('float[2]',{11,22}),8)
    assert(real.writable_data(cell,16) and real.write(cell,xy) and real.read(cell,8)==xy)
    ffi.copy(cell+8,ffi.new('uint8_t *[1]',cell),8)
    assert(real.distance(real.pointer(real.read(cell+8,8)),cell)==0)
end
print('PASS: runtime-backed Windows adapter hashes once per session, refuses module pages and writes checked data')
-- The compiled module embeds the runtime and stops at the missing game modules.
local build_dir=arg[2]
if build_dir then
    local host=setmetatable({print=function()end,os={getenv=function()end},CowboyBingusModLoader={api=1},
        update=function(...)return ... end},{__index=_G});host._G=host
    local previous=host.update
    setfenv(assert(loadfile(build_dir..'/mod.ljbc')),host)()
    local state=host.ReinforcementBeaconFixData
    assert(host.update==previous and state.active==false and state.status:find('Required modules unavailable',1,true),
        state.status)
    print('PASS: compiled module rejects the non-game test host')
end
