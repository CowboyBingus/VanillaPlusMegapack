-- Idle-gate equivalence: the published v4.6 reader (tests/reference/
-- spawn_data.lua, copied from f1df013) and the current one run side by side,
-- each through archive_loader.lua on the runtime's update guard with its own
-- copy of the same fake game, through scripted scenarios of 3,000 frames in
-- all. Every frame each side's outputs are recorded: status, active, the
-- correction count, the pending correction, the last correction, the guard's
-- state and counts, each write (address and bytes), each page check, each
-- printed line, each log write and both pending XY fields.
--
-- The main scenario must be equal frame for frame: the ship, alive frames with
-- a beacon out, co-op deaths (a local beacon, a teammate's unmarked beacon),
-- queued -> pending -> landing, correction frames, a mission end and a restart
-- with a new player manager and its initial deployment, solo deaths (an
-- anchor frozen while the source moves, a second death with the earlier
-- death's automatic row still listed), a pause by an update below while a
-- correction is pending, a mission end while queued, and an unsupported
-- layout while queued, which stops both.
--
-- The KB's documented changes (rbf-idle-gate-2026-10-17) each have their own
-- scenario, where exactly that difference must appear and nothing else:
-- * alive straight to pending (3 -> 2): v4.6 corrects, now skipped;
-- * solo, no landing seen and two automatic rows at the death: v4.6 captures
--   the row new since the last alive frame and corrects, now no anchor;
-- * an unsupported player layout: v4.6 stops while alive, now at the death.
-- A fourth scenario holds what this test found beyond the KB: on loading
-- screens with a null mission-mode or player-manager global, the waiting
-- status (log text only) differs, because the gate reads the player manager
-- first; nothing is read further or written in either.
-- After a skipped correction, the correction count and the log lines that
-- carry it stay one apart; everything else must be equal again.
-- Mutants of the gate must fail.
local source=assert(arg[1])
local tests=arg[0]:gsub('[%w_]+%.lua$','')
local ffi=require('ffi')

local function set(data,offset,ctype,value) ffi.copy(data+offset,ffi.new(ctype..'[1]',value),ffi.sizeof(ctype)) end
local function pointer(data,offset,value) set(data,offset,'uint64_t',value) end
local function integer(data,offset,value) set(data,offset,'uint32_t',value) end
local function number(data,offset,value) set(data,offset,'float',value) end
local function hex(bytes) return (bytes:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local function xy_bytes(x,y) return ffi.string(ffi.new('float[2]',{x,y}),8) end

local GAME,EXE,PM,PM2,MODE,ENTITY,RM,POS=0x10000000,0x20000000,0x30000000,0x31000000,0x40000000,0x50000000,0x60000000,0x70000000
local B1,B2,ENTITIES,USED,HASH,COORDS=0x50001000,0x50002000,0x71000000,0x72000000,0x73000000,0x74000000
local SM,ROWS,CAMERA,OWNER=0x75000000,0x76000000,0x77000000,0x78000000
local GLOBALS={pm=0x3326468,mode=0x33266a0,rm=0x33269c0,pos=0x3326b20,sm=0x33266b0,camera=0x346d560,owner=0x346bf98}

-- One fake game (test_startup.lua's layout): two player managers, a local
-- player entity, two beacons (77 owned here, 78 a teammate's) with positions,
-- up to four automatic-reinforcement rows and the fallback source position.
local function world()
    local W={regions={}}
    local function region(address,size)
        local data=ffi.new('uint8_t[?]',size)
        W.regions[#W.regions+1]={address=address,size=size,data=data}
        return data
    end
    local function find(address,size)
        for _,r in ipairs(W.regions) do
            if address>=r.address and address+size<=r.address+r.size then return r,address-r.address end
        end
        error(string.format('Unbounded fixture access %x + %x',address,size))
    end
    W.globals={}
    for name,rva in pairs(GLOBALS) do W.globals[name]=region(GAME+rva,8) end
    pointer(W.globals.pm,0,PM);pointer(W.globals.mode,0,MODE);pointer(W.globals.rm,0,RM);pointer(W.globals.pos,0,POS)
    pointer(W.globals.sm,0,SM);pointer(W.globals.camera,0,CAMERA);pointer(W.globals.owner,0,OWNER)
    W.managers={[PM]=region(PM,0x440),[PM2]=region(PM2,0x440)}
    for _,p in pairs(W.managers) do
        integer(p,0x84,2);integer(p,0x88,2);pointer(p,0xe8,ENTITY);integer(p,0x2e0,3);integer(p,0x3a8,0x7fff)
        integer(p,0x3b4,0);number(p,0x10c,0);number(p,0x110,0);number(p,0x114,9);number(p,0x12c,5)
    end
    W.p=W.managers[PM]
    W.m=region(MODE,0x44);integer(W.m,8,0);integer(W.m,0x40,1)
    local e=region(ENTITY,24);integer(e,8,5);e[20]=1
    local b1,b2=region(B1,24),region(B2,24);integer(b1,8,77);b1[20]=1;integer(b2,8,78);b2[20]=0
    W.r=region(RM,0x58);integer(W.r,8,4);integer(W.r,12,0);pointer(W.r,0x38,ENTITIES);pointer(W.r,0x48,USED)
    W.es=region(ENTITIES,16);pointer(W.es,0,B1);pointer(W.es,8,B2)
    W.us=region(USED,8)
    local q=region(POS,0x60);integer(q,8,2);pointer(q,0x28,HASH);integer(q,0x30,8);integer(q,0x34,0xffffffff)
    integer(q,0x38,1);pointer(q,0x50,COORDS)
    local hs=region(HASH,64)
    for i=0,7 do integer(hs,8*i,0xffffffff) end
    integer(hs,8*5,77);integer(hs,8*5+4,0);integer(hs,8*6,78);integer(hs,8*6+4,1)
    W.xyz=region(COORDS,24);number(W.xyz,0,11);number(W.xyz,4,22);number(W.xyz,8,33)
    number(W.xyz,12,40);number(W.xyz,16,50);number(W.xyz,20,33)
    W.st=region(SM,0x80);integer(W.st,0x34,0);pointer(W.st,0x78,ROWS)
    W.rows=region(ROWS,4*64)
    W.cam=region(CAMERA,0x48);number(W.cam,0x3c,15);number(W.cam,0x40,25);number(W.cam,0x44,3)
    local api={}
    W.out={writes={},queries={},prints={},logs={}}
    function api.read(address,size)
        local r,o=find(address,size)
        if r.unreadable then return nil end
        return ffi.string(r.data+o,size)
    end
    function api.read_into(address,size,buffer)
        local r,o=find(address,size)
        if r.unreadable then return false end
        ffi.copy(buffer,r.data+o,size);return true
    end
    local function decode(bytes,offset)
        if not bytes then return nil end
        local v=ffi.new('uint64_t[1]');ffi.copy(v,bytes:sub((offset or 0)+1),8)
        local n=tonumber(v[0]);if n<0x10000 or n>=0x800000000000 then return nil end
        return n
    end
    api.pointer=decode
    function api.pointer_at(buffer,offset) return decode(ffi.string(buffer+offset,8)) end
    -- Only either manager's pending XY is writable; like the real adapter, a
    -- write checks the protection itself.
    function api.writable_data(address,size)
        W.out.queries[#W.out.queries+1]=string.format('%x+%d',address,size)
        return (address==PM+0x10c or address==PM2+0x10c) and size==8
    end
    function api.write(address,bytes)
        assert((address==PM+0x10c or address==PM2+0x10c) and #bytes==8,'Only a pending XY may be changed')
        if not api.writable_data(address,#bytes) then return false end
        W.out.writes[#W.out.writes+1]=string.format('%x=%s',address,hex(bytes))
        local r,o=find(address,8);ffi.copy(r.data+o,bytes,8);return true
    end
    function api.module(name) return name and GAME or EXE end
    function api.module_hash(module) return tostring(module) end
    W.api=api
    W.region_at=function(address) return (find(address,1)) end
    return W
end

-- Game events, on one world.
local function mission(W,players)
    integer(W.m,8,1);integer(W.m,0x40,1)
    integer(W.p,0x84,players);integer(W.p,0x88,players)
end
local function beacon(W,which,x,y)
    local i=which==77 and 0 or 1
    integer(W.r,12,1);pointer(W.es,0,which==77 and B1 or B2);integer(W.us,0,0)
    number(W.xyz,12*i,x);number(W.xyz,12*i+4,y)
end
local function row(W,i,x,y)
    integer(W.rows,64*i+12,0x7c);number(W.rows,64*i+16,x);number(W.rows,64*i+20,y);number(W.rows,64*i+24,30)
    integer(W.st,0x34,math.max(i+1,ffi.cast('uint32_t *',W.st+0x34)[0]))
end
local function die(W) integer(W.p,0x2e0,1) end
-- The queue commits: the pod is pending at a scattered XY, the local use bit
-- (bit 0) or only the teammate owner's bit (bit 1) set on the beacon.
local function commit(W,used)
    integer(W.p,0x2e0,2);integer(W.us,0,used);number(W.p,0x10c,50);number(W.p,0x110,60);number(W.p,0x12c,5)
end
local function land(W) integer(W.p,0x2e0,3);integer(W.r,12,0);number(W.p,0x10c,0);number(W.p,0x110,0) end

local function read_file(path)
    local file=assert(io.open(path,'rb'))
    local text=file:read('*a');file:close()
    return text
end
local function replaced(text,old,new)
    local at=text:find(old,1,true)
    assert(at,'mutation target not found: '..old)
    return text:sub(1,at-1)..new..text:sub(at+#old)
end

local LOADER=read_file(source..'/archive_loader.lua')
local function side(spawn_path,setup,mutant)
    local W=world()
    if setup then setup(W) end
    local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
    local text=read_file(spawn_path)
    if mutant then text=replaced(text,mutant[1],mutant[2]) end
    local patch=assert(loadstring(text,'=spawn_data.lua'))()
    local env=setmetatable({},{__index=_G});env._G=env
    env.print=function(line) W.out.prints[#W.out.prints+1]=tostring(line) end
    env.CowboyBingusModLoader={api=1,open_log=function()
        local lines={}
        W.out.logs[#W.out.logs+1]=lines
        return {write=function(_,text) lines[#lines+1]=text end,close=function() end}
    end}
    env.update=function(...)
        local step=W.during;W.during=nil
        if step then step(W) end
        return ...
    end
    env.shutdown=function() end
    setfenv(assert(loadstring(LOADER,'=archive_loader.lua')),env)()(function() return W.api end,patch,
        {revision='eq',game_sha256=tostring(GAME),exe_sha256=tostring(EXE)},runtime)
    W.env=env
    return W
end

-- An assertion's file and line differ between the two copies: left out.
local function located(text) return (text:gsub('%S*spawn_data%.lua:%d+: ','spawn_data.lua: ')) end
local FIELDS={'status','active','corrections','pending','last','guard','writes','queries','prints','logs','xy','raised'}
local function record(W,raised)
    local st,g=W.env.ReinforcementBeaconFixData,W.env.BingusRuntime.statuses.ReinforcementBeaconsFixed
    local o=W.out
    local logs={}
    for i,lines in ipairs(o.logs) do logs[i]=located(table.concat(lines)) end
    local last=st.last and string.format('%s %s %.3f,%.3f %s',st.last.kind,tostring(st.last.beacon),
        st.last.to[1],st.last.to[2],tostring(st.last.association)) or '-'
    local prints={}
    for i,line in ipairs(o.prints) do prints[i]=located(line) end
    local R={status=located(tostring(st.status)),active=tostring(st.active),corrections=st.corrections or 0,
        pending=st.pending and st.pending.bytes and hex(st.pending.bytes) or '-',last=last,
        guard=located(string.format('%s %d %d %d',tostring(g.state),g.errors,g.lower_errors,g.pauses)),
        writes=table.concat(o.writes,','),queries=table.concat(o.queries,','),prints=table.concat(prints,' / '),
        logs=table.concat(logs,' / '),
        xy=hex(ffi.string(W.managers[PM]+0x10c,8)..ffi.string(W.managers[PM2]+0x10c,8)),raised=tostring(raised)}
    W.out={writes={},queries={},prints={},logs={}}
    return R
end
local function differing(A,B)
    local list={}
    for _,k in ipairs(FIELDS) do if A[k]~=B[k] then list[#list+1]=k end end
    return list
end
local function describe(A,B,list)
    local lines={}
    for _,k in ipairs(list) do lines[#lines+1]=string.format('  %s: v4.6 %q, now %q',k,tostring(A[k]),tostring(B[k])) end
    return table.concat(lines,'\n')
end
-- Whether this frame's printed lines report the status (each change prints one).
local function said(R,status) return R.prints:find(': '..status,1,true)~=nil end
-- Only these fields differ (and every one of them does not have to).
local function only(list,allowed)
    local set={}
    for _,k in ipairs(allowed) do set[k]=true end
    for _,k in ipairs(list) do if not set[k] then return false end end
    return true
end
-- After a skipped correction: v4.6 counted one more, and its log lines carry
-- that count and its last correction; everything else is equal.
local function one_correction_apart(A,B,list)
    if not only(list,{'corrections','last','logs'}) or A.corrections~=B.corrections+1 then return false end
    local function plain(logs) return (logs:gsub('corrections=%d+\n',''):gsub('%a+ beacon=[^\n]*\n','')) end
    return plain(A.logs)==plain(B.logs)
end

-- Runs one scenario; returns the labels of the allowed differences seen.
local function play(scenario,mutant)
    local old=side(tests..'reference/spawn_data.lua',scenario.setup)
    local new=side(source..'/spawn_data.lua',scenario.setup,mutant)
    local seen,at={},1
    local function compare(frame,A,B)
        local list=differing(A,B)
        if #list==0 then return end
        local label=scenario.allow and scenario.allow(frame,A,B,list)
        assert(label,string.format('%s, frame %d: undocumented difference\n%s',scenario.name,frame,describe(A,B,list)))
        seen[label]=(seen[label] or 0)+1
    end
    compare(0,record(old,false),record(new,false))
    for frame=1,scenario.frames do
        local step=scenario.steps[at]
        if step and step.t==frame then at=at+1 else step=nil end
        local R={}
        for i,W in ipairs({old,new}) do
            if step and step.before then step.before(W) end
            W.during=step and step.during
            local ok=pcall(W.env.update,0.016)
            R[i]=record(W,not ok)
        end
        compare(frame,R[1],R[2])
    end
    old.env.shutdown();new.env.shutdown()
    compare(scenario.frames+1,record(old,false),record(new,false))
    for _,label in ipairs(scenario.expect or {}) do
        assert(seen[label],scenario.name..': the documented difference "'..label..'" did not appear')
    end
    return old,new,seen
end

local MAIN={name='main',frames=2100,steps={
    {t=100,before=function(W) mission(W,2);beacon(W,77,11,22) end},
    -- Co-op, a local beacon: queued, then pending inside the update.
    {t=300,during=die},
    {t=320,during=function(W) commit(W,1) end},
    {t=360,during=land},
    -- Co-op, a teammate's beacon with only its owner's use bit.
    {t=500,before=function(W) beacon(W,78,40,50) end},
    {t=520,during=die},
    {t=540,during=function(W) commit(W,2) end},
    {t=580,during=land},
    {t=700,before=function(W) integer(W.m,8,0) end},
    -- A restart, solo, with a new player manager: its initial deployment.
    {t=800,before=function(W)
        pointer(W.globals.pm,0,PM2);W.p=W.managers[PM2];integer(W.p,0x2e0,0);mission(W,1) end},
    {t=820,during=function(W) integer(W.p,0x2e0,2);number(W.p,0x10c,5);number(W.p,0x110,5) end},
    {t=850,during=land},
    -- A solo death: the automatic row appears, the source is frozen and then
    -- moves; the correction goes to the frozen source.
    {t=1000,during=function(W) die(W);row(W,0,90,100) end},
    {t=1010,before=function(W) number(W.cam,0x3c,500);number(W.cam,0x40,600) end},
    {t=1020,during=function(W) beacon(W,77,90,100);commit(W,1);number(W.p,0x10c,120);number(W.p,0x110,130) end},
    {t=1060,during=land},
    -- A second solo death with the first death's row still listed.
    {t=1150,before=function(W) number(W.cam,0x3c,30);number(W.cam,0x40,40) end},
    {t=1200,during=function(W) die(W);row(W,1,60,70) end},
    {t=1220,during=function(W) beacon(W,77,60,70);commit(W,1);number(W.p,0x10c,100);number(W.p,0x110,110) end},
    {t=1260,during=function(W) land(W);integer(W.st,0x34,0) end},
    -- A correction pending when an update below raises: restored, paused,
    -- resumed after 60 clean frames.
    {t=1400,during=function(W) die(W);row(W,0,20,30) end},
    {t=1420,during=function(W) beacon(W,77,20,30);commit(W,1) end},
    {t=1430,during=function() error('update below failed',0) end},
    {t=1500,during=function(W) land(W);integer(W.st,0x34,0) end},
    -- The mission ends while queued; a restart and its initial deployment.
    {t=1600,during=die},
    {t=1610,before=function(W) integer(W.m,8,0) end},
    {t=1700,before=function(W) integer(W.p,0x2e0,0);mission(W,1) end},
    {t=1720,during=function(W) integer(W.p,0x2e0,2) end},
    {t=1750,during=land},
    -- An unsupported layout while queued stops both.
    {t=1900,during=die},
    {t=1910,before=function(W) integer(W.p,0x84,5) end},
}}

-- 3 -> 2: a local beacon used, no queued frame.
local SKIP={name='alive to pending',frames=150,expect={'skipped','after'},
    setup=function(W) mission(W,2);beacon(W,77,11,22) end,
    steps={{t=50,before=function(W) commit(W,1) end},{t=90,during=land}},
    allow=function(frame,A,B,list)
        if frame==50 and said(A,'beacon_spawn_centered') and A.writes~='' and A.corrections==1
            and said(B,'pending_without_queue_skipped') and B.writes=='' and B.queries=='' and B.corrections==0
            and B.pending=='-' and A.xy~=B.xy then return 'skipped' end
        if frame>50 and frame<90 and A.status=='reinforcement_already_centered'
            and B.status=='beacon_association_unavailable' and A.writes=='' and B.writes=='' and A.xy~=B.xy
            and only(list,{'status','active','pending','corrections','last','prints','logs','xy'}) then return 'skipped' end
        if frame>=90 and one_correction_apart(A,B,list) then return 'after' end
    end}

-- Solo with no landing seen (the mod starts with the player alive), one row
-- listed already and a second appearing at the death; then a landing, and the
-- next death is corrected by both.
local NO_LANDING={name='no landing seen',frames=300,expect={'no anchor','after'},
    setup=function(W) mission(W,1);beacon(W,77,90,100);row(W,0,70,80) end,
    steps={
        {t=50,during=function(W) die(W);row(W,1,90,100) end},
        {t=70,during=function(W) commit(W,1);number(W.p,0x10c,120);number(W.p,0x110,130) end},
        {t=100,during=land},
        {t=150,before=function(W) number(W.cam,0x3c,30);number(W.cam,0x40,40) end},
        {t=200,during=function(W) die(W);row(W,2,60,70) end},
        {t=220,during=function(W) beacon(W,77,60,70);commit(W,1);number(W.p,0x10c,100);number(W.p,0x110,110) end},
        {t=260,during=land}},
    allow=function(frame,A,B,list)
        if frame==70 and said(A,'solo_spawn_centered') and A.writes~='' and A.corrections==1
            and said(B,'solo_anchor_unavailable') and B.writes=='' and B.queries=='' and B.corrections==0
            and B.pending=='-' then return 'no anchor' end
        if frame>70 and frame<100 and A.status=='reinforcement_already_centered'
            and B.status=='beacon_association_unavailable' and A.writes=='' and B.writes==''
            and only(list,{'status','active','pending','corrections','last','prints','logs','xy'}) then return 'no anchor' end
        if frame>=100 and one_correction_apart(A,B,list) then return 'after' end
    end}

-- An unsupported player layout while alive: v4.6 stops at once, now at the death.
local LAYOUT={name='unsupported layout',frames=150,expect={'met at the death'},
    setup=function(W) mission(W,2);beacon(W,77,11,22) end,
    steps={{t=50,before=function(W) integer(W.p,0x84,5) end},{t=100,during=die}},
    allow=function(frame,A,B,list)
        local stopped=A.status:find('^stopped: .*Unsupported player layout')
        if frame>=50 and frame<=100 and stopped and A.guard:find('^stopped: ') and B.status=='waiting_for_reinforcement'
            and B.guard:find('^running ') and A.writes=='' and B.writes=='' and A.xy==B.xy then return 'met at the death' end
        if frame==101 and A.status==B.status and A.guard==B.guard and B.writes==''
            and only(list,{'prints','logs','queries'}) then return 'met at the death' end
    end}

-- Found by this test, not in the KB: with a null mission-mode or player-manager
-- global (loading screens, the boot), v4.6 reads the mode first and the gate
-- the player manager first, so the waiting status in the log differs.
local LOADING={name='loading screens',frames=300,expect={'waiting text'},
    steps={
        {t=50,before=function(W) pointer(W.globals.mode,0,0) end},
        {t=80,before=function(W) pointer(W.globals.pm,0,0) end},
        {t=110,before=function(W) pointer(W.globals.mode,0,MODE);integer(W.p,0x2e0,0);mission(W,2) end},
        {t=140,before=function(W) pointer(W.globals.pm,0,PM) end},
        {t=160,during=function(W) integer(W.p,0x2e0,2) end},
        {t=190,during=land},
        {t=230,before=function(W) integer(W.m,8,0);pointer(W.globals.pm,0,0) end},
        {t=260,before=function(W) pointer(W.globals.pm,0,PM) end}},
    allow=function(frame,A,B,list)
        local texts={['waiting_for_game_data:mission_mode']=true,['waiting_for_game_data:player_manager']=true,
            waiting_for_reinforcement=true}
        if texts[A.status] and texts[B.status] and A.writes=='' and B.writes=='' and A.queries=='' and B.queries==''
            and A.guard==B.guard and only(list,{'status','prints','logs'}) then return 'waiting text' end
    end}

local SCENARIOS={MAIN,SKIP,NO_LANDING,LAYOUT,LOADING}
local function run_all(mutant)
    local frames,results=0,{}
    for _,s in ipairs(SCENARIOS) do
        frames=frames+s.frames
        local old,new,seen=play(s,mutant)
        results[s.name]={old=old,new=new,seen=seen}
    end
    return frames,results
end

local frames,results=run_all()
assert(next(results.main.seen)==nil,'the main scenario allows no difference')
-- The main scenario did what it is about: five corrections (two co-op, the
-- teammate's unmarked beacon among them, three solo), one restored by the
-- pause, and a stop by the unsupported layout.
local main=results.main.old.env.ReinforcementBeaconFixData
assert(main.corrections==5,'main scenario corrections: '..tostring(main.corrections))
assert(main.status:find('^stopped: .*Unsupported player layout'),main.status)
assert(results.main.old.env.BingusRuntime.statuses.ReinforcementBeaconsFixed.pauses==1)
local loading=results['loading screens'].seen['waiting text']
print(string.format('PASS: idle equivalence with v4.6 over %d frames: the main scenario (2,100 frames: co-op and '
    ..'solo deaths, a teammate\'s beacon, landings, a restart, a pause, a stop) equal frame for frame; the three '
    ..'documented changes appear exactly where expected (alive to pending skipped, no anchor without a landing, '
    ..'an unsupported layout met at the death); loading screens differ only in the waiting status text '
    ..'(%d frames, log only)',frames,loading))

local MUTANTS={
    {'the gate waits through a queued death',{'if spawn~=1 and spawn~=2 then return wait(state,spawn) end',
        'if spawn~=2 then return wait(state,spawn) end'}},
    {'the baseline forgets the landing rows',{'beacons={},automatic=landed,unobserved=true',
        'beacons={},automatic=nil,unobserved=true'}},
    {'alive to pending is not skipped',{'if previous.unobserved then return','if false then return'}},
    {'every check waits at the gate',{'if spawn~=1 and spawn~=2 then return wait(state,spawn) end',
        'do return wait(state,spawn) end'}},
}
for _,m in ipairs(MUTANTS) do
    local ok,why=pcall(run_all,m[2])
    assert(not ok,'mutant passed: '..m[1])
    assert(not tostring(why):find('mutation target not found',1,true),tostring(why))
end
print('PASS: '..#MUTANTS..' mutants of the gate fail the comparison')
