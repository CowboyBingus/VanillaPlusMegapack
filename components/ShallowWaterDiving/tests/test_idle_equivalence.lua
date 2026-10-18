-- Idle-path equivalence: the published v3.10 code (tests/reference/, copied
-- from e9f0ef5) and the current code run side by side, each on the runtime's
-- update guard and its own copy of the same fake game, through one script of
-- 2,650 frames: the ship, a mission, approaching water, dives (assisted, with
-- the startup debt, starting inside the game update, deep, too deep, on dry
-- land, without a water surface), landings, unreadable avatar data, a death
-- and a respawn as another avatar, a non-finite dive timer, an update below
-- that raises during a dive, mission ends while idle and during a dive, and an
-- unsupported player count that stops both.
--
-- Every frame each side's outputs are recorded: status, active, every counter,
-- the lease, the menu result, the guard's state and counts, each write (address
-- and bytes), each page check, each printed line and each log write. The water
-- records both sides write must be equal after every frame. The two event
-- lists (a frame's outputs, kept when anything changed) must be equal, entry
-- for entry and in order. Their frames may differ only by the rework's two
-- documented bounded delays, after a change that the waiting code cannot see
-- at once:
-- * 'gated': the local avatar idle, a change the dive controller does not show
--   (a death, a mission end, an unsupported player count): v3.10 sees it at its
--   next full check (every 31st check, at most 16 frames), this code at the
--   next 120th frame (at most 119 frames);
-- * 'poll': no local avatar (the ship, a death, unreadable avatar data): v3.10
--   checks every frame, this code every 30th frame (at most 29 frames late).
-- Everything else (dives, landings, a failed gate read, errors, pauses) must
-- happen on the same frame. The longest wait of each kind is pinned to its
-- frame, and mutants of the gate and the loader (a gate that never sees a
-- dive, no gate after the update, longer intervals) must fail the comparison.
-- An assertion's file and line are left out of the comparison: they differ
-- between the two copies of the patch.
local source=assert(arg[1])
local tests=arg[0]:gsub('[%w_]+%.lua$','')
local ffi=require('ffi')
local Text=assert(loadfile(source..'/bingus_text.lua'))()
local LOCALES={en=assert(loadfile(source..'/../locales/en.lua'))(),bundled={}}
Text.registry().steam_language='en'

local function put(data,o,kind,v) ffi.copy(data+o,ffi.new(kind..'[1]',v),ffi.sizeof(kind)) end
local function u(d,o,v) put(d,o,'uint32_t',v) end
local function p(d,o,v) put(d,o,'uint64_t',v) end
local function f(d,o,v) put(d,o,'float',v) end
local function number(d,o) return tonumber(ffi.cast('float *',d+o)[0]) end
local function hex(bytes) return (bytes:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end

local GAME,PM,MODE,OWNER,AM,DM,SM,MM=0x10000000,0x20000000,0x21000000,0x30000000,0x40000000,0x50000000,0x51000000,0x52000000
local WATERS=0x53400000
local CONTROLLERS={[0]=0x53d900,[1]=0x53d900+0x1238}
local ROOT_Z=-1.5967556476593018

-- One fake game: test_dive.lua's layout, with both avatar slots (ids 111 and
-- 222) mapped to a water, stance and position record, so the local player can
-- respawn as the other avatar and dive there.
local function world()
    local W={regions={},out=nil,slot=1}
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
    for rva,ptr in pairs({[0x3326468]=PM,[0x33266a0]=MODE,[0x346bf98]=OWNER,[0x3326d20]=AM,[0x3326a80]=DM,
        [0x3326598]=SM,[0x3326558]=MM}) do p(region(GAME+rva,8),0,ptr) end
    for rva,v in pairs({[0x23c6ccc]=0.9,[0x23c69f8]=0.4}) do f(region(GAME+rva,4),0,v) end
    do local constants=region(GAME+0x23c7080,0x100);f(constants,0x90,2);f(constants,0x80,1.5) end
    W.players,W.mission,W.avatars=region(PM,0x400),region(MODE,0x44),region(AM,0x550000)
    local drown,stances,motion=region(DM,80),region(SM,72),region(MM,0x48e0)
    local player=region(0x22000000,24);p(W.players,0xe8,0x22000000);player[20]=1
    u(W.players,0x3a8,9);u(W.players,0x84,2);u(W.players,0x88,2);u(W.mission,8,0);u(W.mission,0x40,1)
    -- A 16-slot map (multiplier 1) holding id -> index for each pair.
    local function map(header,o,address,pairs_)
        p(header,o,address);u(header,o+8,16);u(header,o+12,0xffffffff);u(header,o+16,1)
        local rows=region(address,128)
        for i=0,15 do u(rows,8*i,0xffffffff) end
        for _,kv in ipairs(pairs_) do u(rows,kv[1]%16*8,kv[1]);u(rows,kv[1]%16*8+4,kv[2]) end
        return rows
    end
    W.owner_rows=map(region(OWNER+0xf22ec8,20),0,0x53000000,{{9,1}})
    local entities=region(OWNER+0xf32f18,48)
    for i=0,1 do
        ffi.copy(entities+i*24,'\151\250\077\041\077\051\028\077',8)
        u(entities,i*24+8,i==0 and 111 or 222);u(entities,i*24+12,i==0 and 333 or 444);entities[i*24+20]=1
        p(W.avatars,0x110+i*8,OWNER+0xf32f18+i*24)
    end
    map(W.avatars,0xf8,0x53100000,{{111,0},{222,1}});u(W.avatars,0x6c,2)
    map(drown,32,0x53200000,{{111,0},{222,1}});u(drown,8,2)
    local entityptrs=region(0x53300000,16);p(entityptrs,0,OWNER+0xf32f18);p(entityptrs,8,OWNER+0xf32f18+24)
    p(drown,56,0x53300000)
    W.waters=region(WATERS,56);p(drown,64,WATERS)
    W.enables=region(0x53500000,4);p(drown,72,0x53500000)
    map(stances,24,0x53600000,{{111,0},{222,1}});W.stance=region(0x53700000,112);p(stances,56,0x53700000)
    map(motion,0x48a0,0x53800000,{{111,0},{222,1}});W.pos=region(0x53900000,88);p(motion,0x48d8,0x53900000)
    local resource=region(0x54000000,122*16+6*64);p(region(OWNER+0xf12e20,8),0,0x54000000)
    ffi.copy(resource,'\151\250\077\041\077\051\028\077',8);u(resource,8,5)
    u(resource,122*16+5*64,0x4a182741);f(resource,122*16+5*64+4,-1.3)
    for slot=0,1 do
        local water,ctl=W.waters+28*slot,CONTROLLERS[slot]
        u(W.avatars,ctl+0xb84,slot==0 and 111 or 222);u(W.avatars,ctl+0xf88,0);u(W.avatars,ctl+0xf8c,0)
        f(W.avatars,ctl+0xb84+8,0);f(W.avatars,ctl+0xb84+12,0)
        W.enables[2*slot]=1;W.enables[2*slot+1]=1
        f(water,8,-0.3999999761581421);f(water,16,0.011);f(water,20,4.989);f(water,24,ROOT_Z-2)
        water[0]=1;water[1]=0;u(water,4,0)
        u(W.stance,56*slot+28,2);f(W.pos,44*slot+8,ROOT_Z);W.pos[44*slot+32]=1
    end
    -- The adapter. Reads of an unreadable region fail as ReadProcessMemory does.
    local api={}
    function api.read(a,size,into,offset)
        local r,o=find(a,size)
        if r.unreadable then return nil end
        if into then
            offset=offset or 0
            if size<=0 or offset<0 or offset+size>into.size then return nil end
            ffi.copy(into.data+offset,r.data+o,size)
            return true
        end
        return ffi.string(r.data+o,size)
    end
    -- Only the two floats of either water record may be checked and written.
    local function water_float(a,size)
        for slot=0,1 do
            local record=WATERS+28*slot
            if a>=record+8 and a+size<=record+20 then return true end
        end
        return false
    end
    function api.writable_data(a,size)
        W.out.queries[#W.out.queries+1]=string.format('%x+%d',a,size)
        if not water_float(a,size) then return false end
        return true,WATERS,WATERS+0x1000
    end
    function api.write(a,b,checked)
        assert(#b==4 and water_float(a,4),'Write outside the water floats')
        if not checked and not api.writable_data(a,#b) then return false end
        W.out.writes[#W.out.writes+1]=string.format('%x=%s',a,hex(b))
        local r,o=find(a,4)
        ffi.copy(r.data+o,b,4)
        return true
    end
    function api.module(name) return name and GAME or 1 end
    function api.module_hash(module) return module==GAME and 'game' or 'exe' end
    W.api=api
    W.region_at=function(address) return (find(address,1)) end
    return W
end

-- The script: each step runs on both worlds, before the frame's update or
-- inside the game's update (during), and names the delay it allows.
local function controller(W) return CONTROLLERS[W.slot] end
local function water_of(W) return W.waters+28*W.slot end
local function set_depth(W,depth)
    f(water_of(W),24,ROOT_Z+depth);f(W.pos,44*W.slot+8,ROOT_Z)
end
-- A dive starts: the dive flag, fresh timers, prone, the prone reference and
-- the first prone frame's startup debt in the water record.
local function dive_start(W)
    local ctl,water=controller(W),water_of(W)
    f(W.avatars,ctl+0xb84+8,0);f(W.avatars,ctl+0xb84+12,0)
    f(water,8,-0.3999999761581421);f(water,16,0.011)
    u(W.stance,56*W.slot+28,2)
    u(W.avatars,ctl+0xf8c,0x20);W.diving=true
end
local function dive_over(W) u(W.avatars,controller(W)+0xf8c,0);W.diving=false end
local function landing(W) f(W.avatars,controller(W)+0xb84+12,0.5) end
local STEPS={
    {t=125,kind='poll',label='a mission starts',before=function(W) u(W.mission,8,1) end},
    {t=200,kind='visible',label='approaching shallow water',before=function(W) set_depth(W,0.15) end},
    {t=420,kind='visible',label='an assisted dive with the startup debt',before=dive_start},
    {t=450,kind='visible',label='landing',during=landing},
    {t=455,kind='visible',label='the dive is over',before=dive_over},
    {t=600,kind='visible',label='a dive starts inside the game update',during=dive_start},
    {t=640,kind='visible',label='the dive is over',before=dive_over},
    {t=760,kind='visible',label='a dive in deep water',before=function(W) water_of(W)[1]=1;dive_start(W) end},
    {t=790,kind='visible',label='the dive is over',before=function(W) dive_over(W);water_of(W)[1]=0 end},
    {t=830,kind='visible',label='a dive in water too deep',before=function(W) set_depth(W,0.5);dive_start(W) end},
    {t=850,kind='visible',label='the dive is over',before=dive_over},
    {t=900,kind='visible',label='a dive on dry land',before=function(W) set_depth(W,-0.5);dive_start(W) end},
    {t=920,kind='visible',label='the dive is over',before=dive_over},
    {t=1000,kind='visible',label='leaving the water (no surface)',before=function(W) W.enables[2*W.slot+1]=0 end},
    {t=1010,kind='visible',label='a dive without a water surface',before=dive_start},
    {t=1030,kind='visible',label='the dive is over, back in shallow water',
        before=function(W) dive_over(W);W.enables[2*W.slot+1]=1;set_depth(W,0.15) end},
    {t=1100,kind='visible',label='avatar data unreadable',before=function(W) W.region_at(AM).unreadable=true end},
    {t=1163,kind='poll',label='avatar data readable again',before=function(W) W.region_at(AM).unreadable=false end},
    -- A dive's end is a full check at the step boundary in both; the change
    -- on the next frame is then the longest wait for the 120-frame check
    -- (seen at frame 1410), and a respawn right after that full check the
    -- longest for the 30-frame poll (seen at 1440).
    {t=1280,kind='visible',label='a dive on dry land',before=function(W) set_depth(W,-0.5);dive_start(W) end},
    {t=1290,kind='visible',label='the dive is over',before=dive_over},
    {t=1291,kind='gated',label='the local player dies',before=function(W) u(W.players,0x3a8,0x7fff) end},
    {t=1411,kind='poll',label='respawn as the other avatar',before=function(W)
        u(W.owner_rows,9%16*8+4,0);u(W.players,0x3a8,9);W.slot=0;set_depth(W,0.15) end},
    {t=1520,kind='visible',label='an assisted dive as the new avatar',before=dive_start},
    {t=1550,kind='visible',label='the dive is over',before=dive_over},
    {t=1650,kind='visible',label='a non-finite dive timer',
        before=function(W) f(W.avatars,controller(W)+0xb84+8,0/0) end},
    {t=1652,kind='visible',label='the timer is finite again',
        before=function(W) f(W.avatars,controller(W)+0xb84+8,0) end},
    {t=1700,kind='visible',label='an assisted dive',before=dive_start},
    {t=1715,kind='visible',label='the game update raises during the dive',
        during=function() error('game update failed',0) end},
    {t=1720,kind='visible',label='the dive is over while paused',before=dive_over},
    {t=1880,kind='visible',label='a dive on dry land',before=function(W) set_depth(W,-0.5);dive_start(W) end},
    {t=1890,kind='visible',label='the dive is over',before=dive_over},
    {t=1891,kind='gated',label='the mission ends while idle',before=function(W) u(W.mission,8,0) end},
    {t=2011,kind='poll',label='a mission starts, in shallow water',
        before=function(W) u(W.mission,8,1);set_depth(W,0.15) end},
    {t=2200,kind='visible',label='an assisted dive',before=dive_start},
    {t=2210,kind='visible',label='the mission ends during the dive',before=function(W) u(W.mission,8,0) end},
    {t=2215,kind='visible',label='the dive is over on the ship',before=dive_over},
    {t=2306,kind='poll',label='a mission starts',before=function(W) u(W.mission,8,1) end},
    {t=2450,kind='gated',label='an unsupported player count',before=function(W) u(W.players,0x84,5) end},
}
local FRAMES=2650
local BOUNDS={visible={0,0},gated={-16,119},poll={0,29}}

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

-- One side: a world, the patch and loader under test, a fresh runtime and its
-- own globals. Outputs go to W.out, emptied every frame.
local function side(dive_path,loader_path,mutant)
    local W=world()
    local runtime=assert(loadfile(source..'/bingus_runtime.lua'))()
    local patch=assert(loadfile(dive_path))()
    local loader_text=read_file(loader_path)
    if mutant and mutant.patch then mutant.patch(patch) end
    if mutant and mutant.loader then loader_text=replaced(loader_text,mutant.loader[1],mutant.loader[2]) end
    local env=setmetatable({},{__index=_G});env._G=env
    W.out={writes={},queries={},prints={},logs={}}
    env.print=function(line) W.out.prints[#W.out.prints+1]=tostring(line) end
    env.CowboyBingusModLoader={api=1,version=17,open_log=function()
        local lines={}
        W.out.logs[#W.out.logs+1]=lines
        return {write=function(_,text) lines[#lines+1]=text end,close=function() end}
    end}
    env.update=function()
        local step=W.during;W.during=nil
        if step then step(W) end
        if W.diving then
            local ctl=controller(W)
            f(W.avatars,ctl+0xb84+8,number(W.avatars,ctl+0xb84+8)+1/60)
        end
    end
    env.shutdown=function() end
    local install=setfenv(assert(loadstring(loader_text,'=archive_loader.lua')),env)()
    install(function() return W.api end,patch,{revision='eq',game_sha256='game',exe_sha256='exe'},Text,LOCALES,runtime)
    W.env=env
    return W
end

local function state_line(W)
    local st,g=W.env.ShallowWaterDive,W.env.BingusRuntime.statuses.ShallowWaterDiving
    return table.concat({tostring(st.status),tostring(st.active),st.observed,st.protected,st.restored,
        st.startup_clears,st.short_ends,st.table_moves,st.pending and 'lease' or '-',tostring(st.depth_option),
        st.menu_attempts,tostring(g.state),g.errors,g.lower_errors,g.pauses},' ')
end
-- An assertion's message carries its file and line, which differ between the
-- two copies of the patch: compared without them.
local function located(text) return (text:gsub('%S*dive_data%.lua:%d+: ','dive_data.lua: ')) end
local function flush(W,frame,raised)
    local o=W.out
    local logs={}
    for i,lines in ipairs(o.logs) do logs[i]=located(table.concat(lines)) end
    for i,line in ipairs(o.prints) do o.prints[i]=located(line) end
    local line=located(state_line(W))
    local changed=line~=W.last or #o.writes>0 or #o.queries>0 or #o.prints>0 or #o.logs>0 or raised
    W.last=line
    if changed then
        W.events[#W.events+1]={frame=frame,text=line..' | w '..table.concat(o.writes,',')..' | q '
            ..table.concat(o.queries,',')..' | p '..table.concat(o.prints,' / ')..' | l '..table.concat(logs,' / ')
            ..(raised and ' | raised' or '')}
    end
    W.out={writes={},queries={},prints={},logs={}}
end

-- Runs the script on both sides; returns the comparison's statistics, or
-- raises at the first difference that is not a documented bounded delay.
local function run(mutant)
    local old=side(tests..'reference/dive_data.lua',tests..'reference/archive_loader.lua')
    local new=side(source..'/dive_data.lua',source..'/archive_loader.lua',mutant)
    local sides={old,new}
    for _,W in ipairs(sides) do W.events={};flush(W,0,false) end
    local at=1
    for frame=1,FRAMES do
        local step=STEPS[at]
        if step and step.t==frame then at=at+1 else step=nil end
        for _,W in ipairs(sides) do
            if step and step.before then step.before(W) end
            W.during=step and step.during
            local ok=pcall(W.env.update,1/60)
            flush(W,frame,not ok)
        end
        assert(ffi.string(old.waters,56)==ffi.string(new.waters,56),'water records differ after frame '..frame)
    end
    for _,W in ipairs(sides) do W.env.shutdown();flush(W,FRAMES+1,false) end
    assert(#old.events==#new.events,string.format('%d events in v3.10, %d now',#old.events,#new.events))
    local stats={events=#old.events,gated=0,poll=0,max_gated=0,max_poll=0,old_ahead=0}
    for i,a in ipairs(old.events) do
        local b=new.events[i]
        assert(a.text==b.text,string.format('event %d differs (frames %d / %d):\n  v3.10: %s\n  now:   %s',
            i,a.frame,b.frame,a.text,b.text))
        local governing
        for _,s in ipairs(STEPS) do if s.t<=math.min(a.frame,b.frame) then governing=s end end
        local kind=governing and governing.kind or 'visible'
        local delay,bounds=b.frame-a.frame,BOUNDS[kind]
        assert(delay>=bounds[1] and delay<=bounds[2],string.format(
            'event %d (%s) is %d frames late after "%s" (%s, allowed %d..%d):\n  %s',
            i,a.text,delay,governing and governing.label or 'startup',kind,bounds[1],bounds[2],a.text))
        if delay~=0 then
            stats[kind]=stats[kind]+1
            if delay<0 then stats.old_ahead=stats.old_ahead+1 end
            local key='max_'..kind;if delay>stats[key] then stats[key]=delay end
        end
    end
    return stats,old,new
end

local stats,old,new=run()
-- The script reaches what it is about: every documented delay happens, the
-- dives were assisted and the run ends stopped by the unsupported count.
local st=old.env.ShallowWaterDive
-- The longest waits, pinned: after a dive's end (a full check at the step
-- boundary) a death or a mission end on the next frame is seen 119 frames
-- later (v3.10: at its 31st check, 14 frames later), and a respawn or a
-- mission start right after that full check 29 frames later (v3.10: at once).
local function seen(W,status,from)
    for _,e in ipairs(W.events) do
        if e.frame>=from and e.text:find(status..' ',1,true)==1 then return e.frame end
    end
end
for _,c in ipairs({{'waiting_for_local_avatar',1291,1305,1410},{'dive_ended',1411,1411,1440},
    {'waiting_for_mission',1891,1905,2010},{'dive_ended',2011,2011,2040}}) do
    local a,b=seen(old,c[1],c[2]),seen(new,c[1],c[2])
    assert(a==c[3] and b==c[4],string.format('%s after frame %d: seen at %s (v3.10) and %s, expected %d and %d',
        c[1],c[2],tostring(a),tostring(b),c[3],c[4]))
end
assert(stats.gated>0 and stats.max_gated>16,'no gated delay beyond v3.10\'s own: '..stats.max_gated)
assert(stats.poll>0 and stats.max_poll>0,'no poll delay')
assert(st.protected==5 and st.startup_clears==5 and st.observed==11,
    string.format('protected %d, startup clears %d, observed %d',st.protected,st.startup_clears,st.observed))
assert(st.status:find('^stopped after 8 errors'),st.status)
print(string.format('PASS: idle equivalence with v3.10 over %d frames: %d equal events in order; '
    ..'%d later than v3.10 by the 120-frame idle check (up to %d frames; 119 after the change at most, pinned), '
    ..'%d by the 30-frame poll without an avatar (up to %d, pinned); writes, page checks, logs and water records '
    ..'equal',FRAMES,stats.events,stats.gated,stats.max_gated,stats.poll,stats.max_poll))

-- Mutants the comparison must reject.
local MUTANTS={
    {'a gate that never sees a dive',{patch=function(patch) patch.idle=function() return true end end}},
    {'a full check every 1200th idle frame',{loader={'GATE_FRAMES,POLL_FRAMES=120,30','GATE_FRAMES,POLL_FRAMES=1200,30'}}},
    {'a poll every 300th frame without an avatar',{loader={'GATE_FRAMES,POLL_FRAMES=120,30','GATE_FRAMES,POLL_FRAMES=120,300'}}},
    {'no check after the update while gated',{loader={'if gated and idle(api,state) then return end','if gated then return end'}}},
    {'a full check every 140th idle frame',{loader={'GATE_FRAMES,POLL_FRAMES=120,30','GATE_FRAMES,POLL_FRAMES=140,30'}}},
    {'a poll every 40th frame without an avatar',{loader={'GATE_FRAMES,POLL_FRAMES=120,30','GATE_FRAMES,POLL_FRAMES=120,40'}}},
}
for _,m in ipairs(MUTANTS) do
    local ok,why=pcall(run,m[2])
    assert(not ok,'mutant passed: '..m[1])
    assert(not tostring(why):find('mutation target not found',1,true),tostring(why))
end
print('PASS: '..#MUTANTS..' mutants of the gate and the loader fail the comparison')
