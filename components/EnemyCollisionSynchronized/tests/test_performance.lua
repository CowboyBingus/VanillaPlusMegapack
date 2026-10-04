local source, fixtures = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local M = assert(loadfile(source..'/corpse_data.lua'))(dofile(source..'/corpse_profiles.lua'))
local scene = dofile(fixtures..'/perf_scene.lua')
local production = dofile(source..'/windows_api.lua')()
local memory = ffi.new('uint8_t[16]',{1,2,3,4,5,6,7,8})
local first=assert(production.read(memory,8))
memory[0]=99;assert(production.read(memory,8):byte()==99 and first:byte()==1)
assert(production.read(nil,8)==nil and production.read(memory,32769)==nil)
assert(production.read(memory,0)==nil and production.read(memory,-1)==nil)
local before=production.clock();assert(production.clock()>=before)
local cycles=production.thread_cycles()
assert(cycles==nil or production.thread_cycles()>=cycles,'Thread cycle probe must be optional and monotonic')
local addresses=ffi.new('uintptr_t[2]',{0x12345000,0x23456000})
local encoded=ffi.string(addresses,16)
local pointer_a=production.pointer(encoded)
local pointer_b=production.pointer(encoded,8)
assert(production.address(pointer_a)==0x12345000 and production.address(pointer_b)==0x23456000,
    'Pointer scratch reuse changed a previously decoded value')
assert(production.pointer(encoded,9)==nil and production.pointer(encoded,-1)==nil)
assert(production.pointer(string.rep('\0',8))==nil and production.pointer(string.rep('\255',8))==nil)
-- A view takes a number address as a read does, and rejects the same values.
local at=production.address(memory)
local seen=production.view(at,8);assert(seen~=nil and seen[0]==99 and seen[7]==8,'Number-address view')
assert(production.view(0x100,4)==nil and production.view(at+.5,4)==nil and production.view(0x800000000000,4)==nil)
-- Poses decode IEEE singles from bytes: equal to the FFI conversion for every
-- non-NaN pattern below, and every NaN is an ordinary Lua number NaN.
do
    -- The reference reads the float from the copied string, not from the word
    -- just stored: a compiled trace may load a punned float before that store.
    local word=ffi.new('uint32_t[1]')
    local patterns={0,0x80000000,1,0x807fffff,0x00800000,0x3f800000,0xbf800000,0x7f7fffff,0x7f800000,0xff800000}
    local seed=12345
    for _=1,2000 do seed=(seed*1103515245+12345)%2147483648;patterns[#patterns+1]=(seed*2+seed%2)%4294967296 end
    for _,bits in ipairs(patterns) do
        word[0]=bits
        local bytes=ffi.string(word,4)
        local value=M.floats(bytes,0,1)[1]
        local exponent=math.floor(bits/8388608)%256
        if exponent==255 and bits%8388608~=0 then assert(type(value)=='number' and value~=value,'NaN decode')
        else
            local expected=tonumber(ffi.cast('const float *',bytes)[0])
            assert(value==expected and 1/value==1/expected,string.format('Float decode %08x',bits))
        end
    end
    word[0]=0x7fc00001;local nan=M.floats(ffi.string(word,4),0,1)[1];assert(type(nan)=='number' and nan~=nan)
end

-- Batched checks preserve every byte predicate, including overlapping guards,
-- cache invalidation, changed addresses and fallback across unreadable gaps.
local block=ffi.new('uint8_t[256]');ffi.fill(block,256,3)
local guards={{address=block+4,bytes=string.rep('\3',4)},{address=block+20,bytes=string.rep('\3',4)}}
assert(M.same(production,guards));block[22]=9;assert(not M.same(production,guards));block[22]=3
guards[2].bytes='\3\3\9\3';assert(not M.same(production,guards));guards[2].bytes=string.rep('\3',4)
guards[2].address=block+40;assert(M.same(production,guards));block[40]=9;assert(not M.same(production,guards))
guards[2].address=block+20
guards[#guards+1]={address=block+6,bytes='bad!'};assert(not M.same(production,guards));guards[3]=nil
local underlying=production.read
production.read=function(at,size)if size>4 then return nil end;return underlying(at,size)end
assert(M.same(production,guards),'Unreadable batching gap falls back to individual checks')
production.read=underlying

local function fixture(living,dead,corpses,cost)
    local api={pointer=production.pointer,address=production.address,distance=production.distance}
    local ticks,reads=0,0
    -- Synthetic storage is owned by this process; only benchmark.lua measures
    -- operating-system read overhead. Correctness tests use a deterministic clock.
    api.read=function(at,size)ticks=ticks+(cost or 0);reads=reads+1;return ffi.string(type(at)=='number' and ffi.cast('uint8_t *',at) or at,size)end
    api.clock=function()return ticks end
    local _,g,e,state,f=scene(M,api,living,dead,corpses)
    return api,g,e,state,f,function()return reads end
end
do
    local api,g,e,state,f,reads=fixture(1500,0,0)
    for i=1,20 do
        local scanned,inspected=state.scan_entities or 0,state.deep_inspections or 0
        local old=reads();f.tick(i/30);assert(M.apply(api,g,e,state))
        assert(state.scan_entities-scanned<=M.max_entities and state.deep_inspections-inspected==0)
        assert(reads()-old<300 and state.observed==0,'Living crowds must not trigger deep reads')
    end
    assert(state.budget_yields==20)
end
collectgarbage('collect')
do
    local api,g,e,state,f=fixture(300,24,24)
    local seen,original={},M.plan
    M.plan=function(unit)seen[unit.unit]=true;return original(unit)end
    for i=1,240 do
        local before=state.deep_inspections or 0
        f.tick(i/30);assert(M.apply(api,g,e,state))
        assert(state.deep_inspections-before<=M.max_units)
    end
    M.plan=original
    for _,unit in ipairs(f.units) do assert(seen[unit],'A manager or unit starved') end
    f.u(f.mode+8,0);M.apply(api,g,e,state)
    assert(next(state.fling_history)==nil and next(state.fling_stopped)==nil and next(state.cursors)==nil)
end
collectgarbage('collect')
do
    local api,g,e,state,f=fixture(500,2,2,.00003)
    for i=1,160 do
        local scanned=state.scan_entities or 0
        local deep=state.deep_inspections or 0
        f.tick(i/30);M.apply(api,g,e,state)
        assert(state.scan_entities-scanned<=M.max_entities and state.deep_inspections-deep<=1)
    end
    assert(state.budget_yields>0,'Deadline must end the current work slice')
end
collectgarbage('collect')
-- A large living crowd must still permit repeated observations, arming and a
-- verified stop for a remote corpse. Deliberately expire a later sampling gap:
-- deferred work must never reuse a stale motion baseline to issue a stop.
do
    local api,g,e,state,f=fixture(1500,1,1,.000001)
    local unit=f.units[1]
    for i=1,180 do f.tick(i/30);M.apply(api,g,e,state) end
    assert(state.fling_history[unit] and state.fling_history[unit].armed,'Living crowd prevented motion arming')
    for _,body in ipairs(f.bodies[unit]) do f.matrix(body,2) end
    for i=600,620 do f.tick(i/30);M.apply(api,g,e,state) end
    assert(not state.fling_stops and state.max_revisit_seconds>1,'Expired history was reused to stop motion')
    for i=621,800 do f.tick(i/30);M.apply(api,g,e,state) end
    assert(state.fling_history[unit] and state.fling_history[unit].armed)
    for _,body in ipairs(f.bodies[unit]) do f.matrix(body,4) end
    for i=801,860 do f.tick(i/30);M.apply(api,g,e,state) end
    assert(state.fling_stops==1 and state.fling_stops_verified==1,'Bounded scan missed renewed root motion')
end
collectgarbage('collect')
-- Revalidation must remain between native commands, even though actor headers
-- and guard reads are batched. First command changes identity: no second write.
do
    local api,g,e,state,f=fixture(0,0,1)
    local unit=f.units[1]
    f.matrix(f.bodies[unit][16],2);f.matrix(f.bodies[unit][17],3)
    local calls=0
    state.native.pose=function()
        calls=calls+1;f.u(f.entities[unit]+16,123)
    end
    M.apply(api,g,e,state);assert(calls==1,'Identity change must cancel remaining commands')
end
print('PASS: scratch read ownership, precise batched guards, living-crowd read cap, bounded work, manager fairness, mission reset and between-command identity races')

-- Per-poll call budget. The loader polls at most every M.interval (1/30 s);
-- every frame calls api.time once and a poll adds one more for its report.
-- Guards compare through api.view while it stays paired with api.read, which
-- budget.wrap preserves: the view counts below show that path is taken.
-- Guards within 128 bytes share one view, so each scene is carved from one
-- arena: heap placement would otherwise change the view count between runs.
do
    local budget=dofile(arg[0]:gsub('[%w_]+%.lua$','')..'frame_budget.lua')
    local new,size=ffi.new,0x5c00000
    local arena=new('uint8_t[?]',size)
    local function carve(living,dead,corpses,api)
        local used=0
        ffi.new=function(ct,n,...)
            if ct~='uint8_t[?]' then return new(ct,n,...) end
            local at=arena+used;used=used+n+(-n)%16;assert(used<=size,'arena exhausted')
            ffi.fill(at,n);return at
        end
        local ok,_,g,e,state,f=pcall(scene,M,api,living,dead,corpses)
        ffi.new=new;assert(ok,_)
        return g,e,state,f
    end
    local function poll(label,limits,expected,living,dead,corpses,setup,warm)
        local api={address=production.address,distance=production.distance,pointer=production.pointer,
            read=production.read,view=production.view,view_read=production.view_read,clock=function()return 0 end}
        local g,e,state,f=carve(living,dead,corpses,api)
        local counts=budget.wrap(api)
        if setup then setup(g,f) end
        for i=1,warm or 0 do f.tick(i/30);assert(M.apply(api,g,e,state)) end
        f.tick(1)
        local frame,ok,reason=budget.frame(counts,M.apply,api,g,e,state)
        assert(ok and reason==expected,label..': '..tostring(reason))
        budget.check(frame,limits,label)
        return state
    end
    local pure={address=3,clock=1,distance=1,time=1} -- no system calls
    local function with(limits)for k,v in pairs(pure)do limits[k]=limits[k] or v end;return limits end
    -- Off a mission only the mode is read: the physics-world getter preflight
    -- (3 reads) runs only in a mission.
    poll('outside a mission',with{read=1,pointer=1,address=0,distance=0},'waiting_for_mission',0,0,0,function(g)
        ffi.cast('uint8_t **',g+0x33266a0)[0]=nil end)
    poll('on the ship',with{read=2,pointer=1,address=0,distance=0},'waiting_for_mission',0,0,0,function(g,f)f.u(f.mode+8,0)end)
    poll('idle in a mission',with{read=9,pointer=6},'ready',0,0,0)
    -- Each scanned entry costs one header view (no string unless its resource
    -- is listed); the sync counts of up to 16 listed entries come from one
    -- view at the array's 432-byte stride. The clock is read every 8 scanned
    -- entries and after each inspection, not before every entry (clock 8 -> 1).
    -- address +1 per scanned manager (pure, no system call): the sync count
    -- view takes the sync array's number address.
    poll('eight living enemies',with{read=10,view=9,pointer=17,address=4},'ready',8,0,0)
    -- A settled, aligned corpse is reread in full every poll it is visited (up
    -- to M.max_units per poll): each enabled body (69 here) is one view, a
    -- string only for main and actionable bodies. Each inspection copies the
    -- unit object's three guarded words with one view.
    local state=poll('settled corpse',with{read=25,pointer=19,address=151,view=82},'ready',0,0,1,nil,1)
    assert(state.observed==1 and not state.realignments)
    -- An inspected ragdoll's sync count is the one its eligibility check read;
    -- its two other sync words come from one view. Its identity guards, just
    -- verified by the inspection, are not compared again for the motion sample.
    state=poll('settled remote ragdoll',with{read=28,pointer=19,address=185,view=100},'ready',0,1,0,nil,1)
    assert(state.observed==1 and not state.fling_stops)
    -- Two settled ragdolls behind eight living enemies: the first ragdoll's
    -- count comes from the window copied at entry 0; its inspection discards
    -- the window, so the second's count is copied afresh (a single read here,
    -- as it is the manager's last entry). The clock is read after each
    -- inspection (clock +2).
    state=poll('living enemies and two settled ragdolls',with{read=41,pointer=35,address=362,view=218,clock=3},'ready',8,2,0,nil,1)
    assert(state.observed==2 and not state.fling_stops)
    -- The first command needs only its actor's guards; the unit's are compared
    -- afresh after it.
    state=poll('corpse realignment',with{read=25,pointer=19,address=245,view=95},'ready',0,0,1,function(g,f)
        f.matrix(f.bodies[f.units[1]][16],2) end)
    assert(state.realignments==1)
    -- Garbage per poll, collector held, with the production read, view,
    -- pointer, address and distance, in bytes per poll (interpreted, compiled):
    -- - Idle polls allocate nothing (no closure, table, string or cdata)
    --   outside a mission, on the ship and idle in a mission: exactly 0.
    -- - A poll that scans eight living enemies allocates nothing: each sync
    --   count read takes a number address (it made a 16 B pointer each before).
    -- - A poll that inspects one settled corpse or ragdoll, or realigns a
    --   corpse actor every poll, allocates what the unit record, its guards and
    --   decoded poses need: at most the limits below. Their exact counts vary
    --   by a few bytes with table resizes that depend on earlier polls. The
    --   per-unit inspection closure the split M.snapshot no longer makes cost
    --   about 600 B interpreted and 1.5 KB compiled per inspection, more than
    --   any margin here.
    -- Interpreted counts do not depend on which traces get compiled. A full
    -- collection frees interned strings and pointer objects nobody holds,
    -- which the next polls make once more, so the counted window starts ten
    -- polls after it. Compiled: the median of ten windows after 300 warm-up
    -- polls (a window that compiles a trace also counts its trace data).
    local garbage={
        {'outside a mission',0,0,0,0,0,function(g)ffi.cast('uint8_t **',g+0x33266a0)[0]=nil end}, -- lint-ok: R3 test scene
        {'on the ship',0,0,0,0,0,function(g,f)f.u(f.mode+8,0)end},
        {'idle in a mission',0,0,0,0,0},
        {'eight living enemies',8,0,0,0,0},
        {'settled corpse',0,0,1,23700,22400},
        {'settled remote ragdoll',0,1,0,36950,33600},
        {'corpse realignment',0,0,1,34700,33400,nil,true},
    }
    local function garbage_polls(item)
        local api={address=production.address,distance=production.distance,pointer=production.pointer,
            read=production.read,view=production.view,view_read=production.view_read,clock=function()return 0 end}
        local g,e,s,f=carve(item[2],item[3],item[4],api)
        if item[7] then item[7](g,f) end
        local tick=0
        return function(n)
            for _=1,n do
                tick=tick+1
                if item[8] then f.matrix(f.bodies[f.units[1]][16],2+tick%2) end
                f.tick(tick/30);assert(M.apply(api,g,e,s))
            end
        end
    end
    local function per_poll(polls,n)
        collectgarbage('stop') -- lint-ok: R4 test only: hold the collector while counting bytes
        local before=collectgarbage('count')
        polls(n)
        local grown=(collectgarbage('count')-before)*1024
        collectgarbage('restart') -- lint-ok: R4 test only: undo the stop above
        return grown/n
    end
    -- Exactly the limit for polls that inspect nothing, at most for inspections.
    local function check(item,bytes,limit,how)
        local inspects=item[3]+item[4]>0
        assert(bytes==limit or inspects and bytes<=limit,item[1]..': '..bytes..' bytes per '..how..' poll, limit '..limit)
    end
    jit.flush();jit.off() -- lint-ok: R5 test only: count the interpreted path
    for _,item in ipairs(garbage) do
        local polls=garbage_polls(item)
        polls(10);collectgarbage('collect');polls(10) -- lint-ok: R4 test only: settle the heap before counting
        check(item,per_poll(polls,100),item[5],'interpreted')
    end
    jit.on() -- lint-ok: R5 test only: undo the jit.off above
    for _,item in ipairs(garbage) do
        local polls=garbage_polls(item)
        polls(300)
        local windows={}
        for i=1,10 do polls(10);windows[i]=per_poll(polls,100) end
        table.sort(windows)
        check(item,(windows[5]+windows[6])/2,item[6],'compiled')
    end
end
print('PASS: per-poll call budget: no protection queries; 1 read outside a mission, 2 on the ship, 9 idle in a mission, views validate guards, one realignment; garbage per poll interpreted and compiled: idle polls nothing, eight living enemies nothing, inspections pinned')
